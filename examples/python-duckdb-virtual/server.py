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
from perspective.virtual_servers.sql_builder import (
    CTE, grouping, max_, order_by, raw, sum_, eq, case, when,
    select_col, window, row_number, abs_, tableref, lit
)
from tornado.web import StaticFileHandler


INPUT_FILE = (
    Path(__file__).parent.resolve()
    / "node_modules"
    / "superstore-arrow"
    / "superstore.parquet"
)

db = duckdb.connect(":memory:perspective")
table_data = {
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

rows = [reduce(lambda acc, col_name: {**acc, col_name: table_data[col_name][i]}, table_data.keys(), {}) for i in range(len(table_data["division"]))]


with open("test.json", 'w') as f:
    json.dump(rows, f)

_ =db.read_json("test.json")

class GmvAggregate(CustomAggregate):
    def __init__(self):
        super().__init__(CustomAggregateType.NUMBER, "sums")

    @override
    def build_cte(self, cte_name, col, group_by, table):
        n = len(group_by)
        columns = []
        for g in group_by:
            columns.append(select_col(g))

        columns.append(select_col(sum_(col), f"{col.name}_sum"))

        if n == 1:
            return [CTE(cte_name, columns, table.name, group_by=group_by)]

        for k in range(n - 1, 0, -1):
            if k == n:
                partition_cols = [group_by[-1]]
                total_name = f"{col.name}_total_across_{group_by[0].name}"
            else:
                num_groups = n - k
                partition_cols = group_by[:num_groups] + [group_by[-1]]
                total_name = f"{col.name}_total_at_level_{k}"

            columns.append(select_col(
                window(sum_(sum_(col)), partition_by=partition_cols),
                total_name
            ))
            columns.append(select_col(
                window(row_number(), partition_by=partition_cols, order_by=[order_by(group_by[0])]),
                f"{total_name}_row_num"
            ))

        columns.append(select_col(
            window(sum_(sum_(col)), partition_by=[group_by[-1]]),
            f"{col.name}_total_across_all"
        ))
        columns.append(select_col(
            window(row_number(), partition_by=[group_by[-1]], order_by=[order_by(group_by[0])]),
            f"{col.name}_total_across_all_row_num"
        ))

        return [CTE(cte_name, columns, table.name, group_by=group_by)]

    @override
    def build_select(self, cte_table, col, group_by):
        n = len(group_by)
        if n == 1:
            case_expr = case(
                when(
                    eq(grouping(group_by[0]), 1),
                    sum_(abs_(cte_table.col(f"{col.name}_sum")))
                ),
                else_clause=sum_(cte_table.col(f"{col.name}_sum"))
            )
            return select_col(case_expr, col.name)
        else:
            when_clauses = []

            total_grouping_id = 2**n - 1
            when_clauses.append(when(
                eq(grouping(*group_by), total_grouping_id),
                sum_(case(
                    when(cte_table.col(f"{col.name}_total_across_all_row_num").eq(1), abs_(cte_table.col(f"{col.name}_total_across_all"))),
                    else_clause=lit(0)
                ))
            ))

            for k in range(n - 1, 0, -1):
                grouping_id = 2**k - 1
                total_name = f"{col.name}_total_at_level_{k}"
                row_num_name = f"{total_name}_row_num"
                when_clauses.append(when(
                    eq(grouping(*group_by), grouping_id),
                    sum_(case(
                        when(cte_table.col(row_num_name).eq(1), abs_(cte_table.col(total_name))),
                        else_clause=lit(0)
                    ))
                ))

            case_expr = case(*when_clauses, else_clause=sum_(cte_table.col(f"{col.name}_sum")))
            return select_col(case_expr, col.name)

class CumulativeSumAggregate(CustomAggregate):
    def __init__(self):
        super().__init__(CustomAggregateType.NUMBER, "cumsum")

    @override
    def build_cte(self, cte_name, col, group_by, table):
        group_by = group_by
        group_cols = [select_col(g) for g in group_by]
        base_table = tableref(f"{cte_name}_base")
        final_table = tableref(cte_name)

        if len(group_by) == 1:
            base_cte = CTE(
                base_table.name,
                group_cols + [select_col(
                    window(
                        sum_(col),
                        partition_by=group_by,
                        order_by=[order_by(raw("ROWID"))],
                        frame="ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW"
                    ),
                    f"{col.name}_raw"
                )],
                table.name
            )

            final_cte = CTE(
                final_table.name,
                group_cols + [select_col(max_(base_table.col(f"{col.name}_raw")), final_table.name)],
                base_table.name,
                group_by=group_by
            )
        else:
            base_cte = CTE(
                base_table.name,
                group_cols + [select_col(sum_(col), f"{col.name}_sum")],
                table.name,
                group_by=group_by
            )

            partition_by = group_by[:-1] if len(group_by) > 1 else group_by
            final_cte = CTE(
                final_table.name,
                group_cols + [
                    select_col(
                        window(
                            sum_(base_table.col(f"{col.name}_sum")),
                            partition_by=partition_by,
                            order_by=[order_by(group_by[-1])],
                            frame="ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW"
                        ),
                        f"{col.name}_cumsum"
                    ),
                    select_col(base_table.col(f"{col.name}_sum"))
                ],
                base_table.name
            )

        return [base_cte, final_cte]

    @override
    def build_select(self, cte_table, col, group_by):
        n = len(group_by)

        if n == 1:
            case_expr = case(
                when(
                    raw(f"GROUPING({group_by[0].to_sql()}) = 1"),
                    sum_(cte_table.col(f"{col.name}_cumsum"))
                ),
                else_clause=max_(cte_table.col(f"{col.name}_cumsum"))
            )
            return select_col(case_expr, col.name)
        else:
            case_expr = case(
                when(
                    raw(f"GROUPING({', '.join(e.to_sql() for e in group_by)}) = 0"),
                    max_(cte_table.col(f"{col.name}_cumsum"))
                ),
                else_clause=sum_(cte_table.col(f"{col.name}_cumsum"))
            )
            return select_col(case_expr, col.name)


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
