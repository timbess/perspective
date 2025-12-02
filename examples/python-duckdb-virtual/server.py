#  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
#  ┃ ██████ ██████ ██████       █      █      █      █      █ █▄  ▀███ █       ┃
#  ┃ ▄▄▄▄▄█ █▄▄▄▄▄ ▄▄▄▄▄█  ▀▀▀▀▀█▀▀▀▀▀ █ ▀▀▀▀▀█ ████████▌▐███ ███▄  ▀█ █ ▀▀▀▀▀ ┃
#  ┃ █▀▀▀▀▀ █▀▀▀▀▀ █▀██▀▀ ▄▄▄▄▄ █ ▄▄▄▄▄█ ▄▄▄▄▄█ ████████▌▐███ █████▄   █ ▄▄▄▄▄ ┃
#  ┃ █      ██████ █  ▀█▄       █ ██████      █      ███▌▐███ ███████▄ █       ┃
#  ┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫
#  ┃ Copyright (c) 2017, the Perspective Authors.                              ┃
#  ┃ ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌ ┃
#  ┃ This file is part of the Perspective library, distributed under the terms ┃
#  ┃ of the [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). ┃
#  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
from functools import reduce
import threading
import json
from typing import cast, override

from pathlib import Path
from threading import Thread

import duckdb
import perspective
import perspective.handlers.tornado
import perspective.virtual_servers.duckdb
import tornado.ioloop
import tornado.web

from loguru import logger
from perspective.virtual_servers.duckdb import CustomAggregate, CustomAggregateType
from tornado.web import StaticFileHandler


INPUT_FILE = (
    Path(__file__).parent.resolve()
    / "node_modules"
    / "superstore-arrow"
    / "superstore.parquet"
)

db = duckdb.connect(":memory:perspective")
table = {
    "division": [
        "D1", "D2", "D1", "D2", "D1",
        "D2", "D1", "D2", "D1", "D2",
        "D1", "D2", "D1", "D2", "D1",
        "D2", "D1", "D2", "D1", "D2"
    ],
    "trading area": [
        "A", "B", "C", "D", "E",
        "A", "B", "C", "D", "E",
        "A", "B", "C", "D", "E",
        "A", "B", "C", "D", "E"
    ],
    "symbol": [
        "AAPL", "GOOG", "MSFT", "AAPL", "GOOG",
        "MSFT", "AAPL", "GOOG", "MSFT", "AAPL",
        "GOOG", "MSFT", "AAPL", "GOOG", "MSFT",
        "AAPL", "GOOG", "MSFT", "AAPL", "GOOG"
    ],
    "MV": [
        1500, 1200, 1300, 1400, 1600,
        1100, 1700, 1800, 1900, 2000,
        -2100, -2200, -2300, -2400, -2500,
        -2600, -2700, -2800, -2900, -3000
    ],
    "MVCOPY": [
        1500, 1200, 1300, 1400, 1600,
        1100, 1700, 1800, 1900, 2000,
        -2100, -2200, -2300, -2400, -2500,
        -2600, -2700, -2800, -2900, -3000
    ]
}

rows = [reduce(lambda acc, col_name: {**acc, col_name: table[col_name][i]}, table.keys(), {}) for i in range(len(table["division"]))]


with open("test.json", 'w') as f:
    json.dump(rows, f)

_ =db.read_json("test.json")

class GmvAggregate(CustomAggregate):
    @property
    def underlying_type(self) -> CustomAggregateType:
        return CustomAggregateType.NUMBER

    @property
    def cte_suffix(self) -> str:
        return "sums"

    def build_cte(self, col, col_name_fn, group_by, table_name):
        """Build the CTE that pre-calculates needed values."""
        groups = ", ".join(col_name_fn(g) for g in group_by)
        n = len(group_by)

        if n == 1:
            # Simple case: just one grouping level
            return f"""
            {col}_{self.cte_suffix} AS (
                SELECT
                    {groups},
                    sum({col_name_fn(col)}) AS {col}_{self.cte_suffix}
                FROM {table_name}
                GROUP BY {groups}
            )
            """
        else:
            group_list = [col_name_fn(g) for g in group_by]

            window_funcs = []
            row_num_partitions = []

            for k in range(n - 1, 0, -1):
                if k == n:
                    # Total row: partition by last group only
                    partition_cols = [group_list[-1]]
                    total_name = f"{col}_total_across_{group_by[0]}"
                else:
                    # Intermediate rollup: partition by first (n-k) groups + last group
                    num_groups = n - k
                    partition_cols = group_list[:num_groups] + [group_list[-1]]
                    total_name = f"{col}_total_at_level_{k}"

                partition_by = ", ".join(partition_cols)
                window_funcs.append(
                    f"sum(sum({col_name_fn(col)})) OVER (PARTITION BY {partition_by}) AS {total_name}"
                )
                row_num_partitions.append(
                    f"ROW_NUMBER() OVER (PARTITION BY {partition_by} ORDER BY {group_list[0]}) AS {total_name}_row_num"
                )

            # Add total across everything (for grand total)
            window_funcs.append(
                f"sum(sum({col_name_fn(col)})) OVER (PARTITION BY {group_list[-1]}) AS {col}_total_across_all"
            )
            row_num_partitions.append(
                f"ROW_NUMBER() OVER (PARTITION BY {group_list[-1]} ORDER BY {group_list[0]}) AS {col}_total_across_all_row_num"
            )

            return f"""
            {col}_{self.cte_suffix} AS (
                SELECT
                    {groups},
                    sum({col_name_fn(col)}) AS {col}_sum,
                    {", ".join(window_funcs)},
                    {", ".join(row_num_partitions)}
                FROM {table_name}
                GROUP BY {groups}
            )
            """

    def build_select(self, col, col_name_fn, group_by):
        """Build the SELECT expression with CASE logic for different grouping levels.

        Generates a separate CASE branch for each rollup level:
        - Total row: Deduplicate using total_across_all
        - Each intermediate rollup: Deduplicate using total_at_level_k
        - Leaf level: Raw sum
        """
        groups = ", ".join(col_name_fn(g) for g in group_by)
        n = len(group_by)

        if n == 1:
            return f"""CASE
                WHEN GROUPING({groups}) = 1 THEN SUM(ABS({col}_sum))
                ELSE SUM({col}_sum)
            END AS "{col}" """
        else:
            # For ROLLUP(a, b, c), GROUPING_ID values are:
            #   - 7 (111): total - all grouped
            #   - 3 (011): GROUP BY a - b,c grouped
            #   - 1 (001): GROUP BY a,b - c grouped
            #   - 0 (000): GROUP BY a,b,c - leaf

            case_branches = []

            # Total row: GROUPING_ID = 2^n - 1
            total_grouping_id = 2**n - 1
            case_branches.append(
                f"WHEN GROUPING({groups}) = {total_grouping_id} THEN "
                f"SUM(CASE WHEN {col}_total_across_all_row_num = 1 THEN ABS({col}_total_across_all) ELSE 0 END)"
            )

            # Intermediate rollup levels: GROUPING_ID = 2^k - 1 for k = n-1, n-2, ..., 1
            # Each intermediate level uses its pre-computed total with deduplication
            for k in range(n - 1, 0, -1):
                grouping_id = 2**k - 1
                total_name = f"{col}_total_at_level_{k}"
                row_num_name = f"{total_name}_row_num"
                case_branches.append(
                    f"WHEN GROUPING({groups}) = {grouping_id} THEN "
                    f"SUM(CASE WHEN {row_num_name} = 1 THEN ABS({total_name}) ELSE 0 END)"
                )

            # Leaf level: GROUPING_ID = 0
            case_branches.append(f"ELSE SUM({col}_sum)")

            case_statement = "CASE\n                " + "\n                ".join(case_branches) + "\n            END"
            return f"""{case_statement} AS "{col}" """

# Honestly no idea if this is right, but it's mostly to show two custom aggregates working together.
class CumulativeSumAggregate(CustomAggregate):
    @property
    def underlying_type(self) -> CustomAggregateType:
        return CustomAggregateType.NUMBER

    @property
    def cte_suffix(self) -> str:
        return "cumsum"

    def build_cte(self, col, col_name_fn, group_by, table_name):
        groups = ", ".join(col_name_fn(g) for g in group_by)
        n = len(group_by)

        if n == 1:
            # Simple case: cumulative sum within each group
            return f"""
            {col}_{self.cte_suffix} AS (
                SELECT
                    {groups},
                    SUM({col_name_fn(col)}) OVER (PARTITION BY {groups} ORDER BY ROWID ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS {col}_{self.cte_suffix}
                FROM {table_name}
            )
            """
        else:
            # Multiple grouping levels - compute cumulative sum for leaf level
            group_list = [col_name_fn(g) for g in group_by]
            partition_by = ", ".join(group_list[:-1]) if len(group_list) > 1 else group_list[0]

            return f"""
            {col}_{self.cte_suffix}_base AS (
                SELECT
                    {groups},
                    SUM({col_name_fn(col)}) AS {col}_sum
                FROM {table_name}
                GROUP BY {groups}
            ),
            {col}_{self.cte_suffix} AS (
                SELECT
                    {groups},
                    SUM({col}_sum) OVER (PARTITION BY {partition_by} ORDER BY {group_list[-1]} ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS {col}_cumsum,
                    {col}_sum
                FROM {col}_{self.cte_suffix}_base
            )
            """

    def build_select(self, col, col_name_fn, group_by):
        groups = ", ".join(col_name_fn(g) for g in group_by)
        n = len(group_by)

        if n == 1:
            # Simple case
            return f"""CASE
                WHEN GROUPING({groups}) = 1 THEN SUM({col}_cumsum)
                ELSE MAX({col}_cumsum)
            END AS "{col}" """
        else:
            # Use cumsum at leaf, sum at higher levels
            return f"""CASE
                WHEN GROUPING({groups}) = 0 THEN MAX({col}_cumsum)
                ELSE SUM({col}_cumsum)
            END AS "{col}" """


def main():
    _ = db.sql(
        f"""
        SET default_null_order=NULLS_FIRST_ON_ASC_LAST_ON_DESC;
        CREATE TABLE data_source_one AS
            SELECT * FROM 'test.json';
        """,
    )

    # Configure custom aggregates by aggregate name (not column name)
    # These will appear in the UI dropdown for numeric columns
    custom_aggregates = {
        "gmv": GmvAggregate(),
        "cumsum": CumulativeSumAggregate(),
    }

    virtual_server = perspective.virtual_servers.duckdb.DuckDBVirtualServer(
        db, custom_aggregates=custom_aggregates
    )
    app = tornado.web.Application(
        [
            (
                r"/websocket",
                perspective.handlers.tornado.PerspectiveTornadoHandler,
                {"perspective_server": virtual_server},
            ),
            (r"/node_modules/(.*)", StaticFileHandler, {"path": "../../node_modules/"}),
            (
                r"/(.*)",
                StaticFileHandler,
                {"path": "./", "default_filename": "index.html"},
            ),
        ],
        websocket_max_message_size=100 * 1024 * 1024,
    )

    _ = app.listen(3000)
    logger.info("Listening on http://localhost:3000")
    loop = tornado.ioloop.IOLoop.current()
    start_event.set()
    loop.start()

start_event = threading.Event()

def watcher():
    from os import path
    from watchdog.events import FileSystemEvent, FileSystemEventHandler, FileModifiedEvent
    from watchdog.observers import Observer

    class SqlEventHandler(FileSystemEventHandler):
        @override
        def on_any_event(self, event: FileSystemEvent) -> None:
            try:
                if isinstance(event, FileModifiedEvent):
                    p = Path(cast(str, event.src_path))
                    if p.suffix == ".sql":
                        content = p.read_text()
                        res = db.sql(content)
                        res.show(max_rows=100)
            except Exception:
                logger.exception("Query Failed")

    event_handler = SqlEventHandler()
    observer = Observer()
    _ = observer.schedule(event_handler, path.dirname(__file__), recursive=True)
    observer.start()
    observer.join()

if __name__ == "__main__":
    print("INPUT_FILE", INPUT_FILE)
    thread = Thread(target=main)
    thread.start()

    _ = start_event.wait()

    watcher()
