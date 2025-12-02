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

import duckdb
import perspective

from abc import ABC, abstractmethod
from datetime import datetime
from loguru import logger
from enum import Enum

from perspective.virtual_servers import VirtualSessionModel

# TODO(texodus): Missing these features
#
# - `min_max` API for value-coloring and value-sizing.
#
# - row expand/collapse in the datagrid needs datamodel support, this is
#   likely a "collapsed" boolean column in the temp table we `UPDATE`.
#
# - `on_update` real-time support will be method which takes sa view name and
#   a handler and calls the handler when the view needs to be recalculated.
#
# Nice to have:
#
# - Optional `view_change` method can be implemented for engine optimization,
#   defaulting to just delete & recreate (as Perspective engine does now).
#
# - Would like to add a metadata API so that e.g. Viewer debug panel could
#   show internal generated SQL.


NUMBER_AGGS = [
    "sum",
    "count",
    "any_value",
    "arbitrary",
    # "arg_max",
    # "arg_max_null",
    # "arg_min",
    # "arg_min_null",
    "array_agg",
    "avg",
    "bit_and",
    "bit_or",
    "bit_xor",
    "bitstring_agg",
    "bool_and",
    "bool_or",
    "countif",
    "favg",
    "fsum",
    "geomean",
    # "histogram",
    # "histogram_values",
    "kahan_sum",
    "last",
    # "list"
    "max",
    # "max_by"
    "min",
    # "min_by"
    "product",
    "string_agg",
    "sumkahan",
    # "weighted_avg",
]

STRING_AGGS = [
    "count",
    "any_value",
    "arbitrary",
    "first",
    "countif",
    "last",
    "string_agg",
]

FILTER_OPS = [
    "==",
    "!=",
    "LIKE",
    "IS DISTINCT FROM",
    "IS NOT DISTINCT FROM",
    ">=",
    "<=",
    ">",
    "<",
]

class CustomAggregateType(Enum):
    NUMBER = 1
    STRING = 2

class CustomAggregate(ABC):
    @abstractmethod
    def build_cte(self, col, col_name_fn, group_by, table_name):
        pass

    @abstractmethod
    def build_select(self, col, col_name_fn, group_by):
        pass

    @property
    @abstractmethod
    def cte_suffix(self) -> str:
        pass

    @property
    @abstractmethod
    def underlying_type(self) -> CustomAggregateType:
        pass

class DuckDBVirtualSession:
    def __init__(self, callback, db, custom_aggregates=None):
        self.session = perspective.VirtualServer(
            DuckDBVirtualSessionModel(db, custom_aggregates)
        )
        self.callback = callback

    def handle_request(self, msg):
        self.callback(self.session.handle_request(msg))


class DuckDBVirtualServer:
    def __init__(self, db, custom_aggregates=None):
        self.db = db
        self.custom_aggregates = custom_aggregates or {}

    def new_session(self, callback):
        return DuckDBVirtualSession(callback, self.db, self.custom_aggregates)


class DuckDBVirtualSessionModel(VirtualSessionModel):
    def __init__(self, db, custom_aggregates: dict[str, CustomAggregate]=None):
        self.db = db
        self.custom_aggregates = custom_aggregates or {}

    def get_features(self):
        number_aggs = NUMBER_AGGS.copy()
        string_aggs = STRING_AGGS.copy()

        for agg_name, agg_class in self.custom_aggregates.items():
            # No switch :'(
            {
                CustomAggregateType.NUMBER: number_aggs,
                CustomAggregateType.STRING: string_aggs,
            }.get(agg_class.underlying_type, []).append(agg_name)

        return {
            "group_by": True,
            "split_by": True,
            "sort": True,
            "expressions": True,
            "filter_ops": {
                "integer": FILTER_OPS,
                "float": FILTER_OPS,
                "string": FILTER_OPS,
                "boolean": FILTER_OPS,
                "date": FILTER_OPS,
                "datetime": FILTER_OPS,
            },
            "aggregates": {
                "integer": number_aggs,
                "float": number_aggs,
                "string": string_aggs,
                "boolean": string_aggs,
                "date": string_aggs,
                "datetime": string_aggs,
            },
        }

    def get_hosted_tables(self):
        logger.info("SHOW ALL TABLES")
        results = self.db.sql("SHOW ALL TABLES").fetchall()
        return [result[2] for result in results]

    def table_schema(self, table_name):
        query = f"DESCRIBE {table_name}"
        results = run_query(self.db, query)
        return {
            result[0].split("_")[-1]: duckdb_type_to_psp(result[1])
            for result in results
            if not (result[0].startswith("__") and result[0].endswith("__"))
        }

    def table_columns_size(self, table_name, config):
        # TODO split this into 2 methods
        query = f"SELECT COUNT(*) FROM (DESCRIBE {table_name})"
        results = run_query(self.db, query)
        gs = len(config["group_by"])
        return results[0][0] - (
            0 if gs == 0 else gs + (1 if len(config["split_by"]) == 0 else 0)
        )

    def table_size(self, table_name):
        query = f"SELECT COUNT(*) FROM {table_name}"
        results = run_query(self.db, query)
        return results[0][0]

    def view_schema(self, view_name, config):
        return self.table_schema(view_name)

    def view_size(self, view_name):
        return self.table_size(view_name)

    def table_make_view(self, table_name, view_name, config):
        columns = config["columns"]
        group_by = config["group_by"]
        split_by = config["split_by"]
        aggregates = config["aggregates"]
        sort = config["sort"]

        columns_with_custom_aggs = {
            col: aggregates[col]
            for col in columns
            if aggregates.get(col) in self.custom_aggregates
        }
        has_custom_aggs = len(columns_with_custom_aggs) > 0

        def col_name(col):
            return expr if (expr := config["expressions"].get(col)) else f'"{col}"'

        def select_clause():
            if len(group_by) > 0:
                for col in columns:
                    yield f'{aggregates.get(col)}({col_name(col)}) as "{col}"'

                if len(split_by) == 0:
                    for idx, group in enumerate(group_by):
                        yield f"{col_name(group)} as __ROW_PATH_{idx}__"

                    groups = ", ".join(col_name(g) for g in group_by)
                    yield f"GROUPING_ID({groups}) AS __GROUPING_ID__"
            elif len(columns) > 0:
                for col in columns:
                    yield f'''{col_name(col)} as "{col.replace('"', '""')}"'''

        def order_by_clause():
            if len(group_by) > 0:
                for gidx in range(len(group_by)):
                    groups = ", ".join(col_name(g) for g in group_by[: (gidx + 1)])
                    if len(split_by) == 0:
                        yield f"""GROUPING_ID({groups}) DESC"""

                    for sort_col, sort_dir in sort:
                        if sort_dir != "none":
                            agg = aggregates.get(sort_col)
                            if gidx >= len(group_by) - 1:
                                yield f"{agg}({col_name(sort_col)}) {sort_dir}"
                            else:
                                yield f"""
                                    first({agg}({col_name(sort_col)}))
                                    OVER __WINDOW_{gidx}__ {sort_dir}
                                """

                    yield f"__ROW_PATH_{gidx}__  ASC"
            else:
                for sort_col, sort_dir in sort:
                    if sort_dir is not None:
                        yield f"{col_name(sort_col)} {sort_dir}"

        def window_clause():
            if len(config["sort"]) == 0:
                return

            for gidx in range(len(group_by) - 1):
                partition = ", ".join(f"__ROW_PATH_{i}__" for i in range(gidx + 1))
                sub_groups = ", ".join(col_name(g) for g in group_by[: (gidx + 1)])
                groups = ", ".join(col_name(g) for g in group_by)
                yield f"""
                    __WINDOW_{gidx}__ AS (
                        PARTITION BY
                            GROUPING_ID({sub_groups}),
                            {partition}
                        ORDER BY
                            {groups}
                )"""

        def where_clause():
            for name, op, value in config["filter"]:
                if value is not None:
                    term_lit = f"'{value}'" if isinstance(value, str) else str(value)
                    yield f"{col_name(name)} {op} {term_lit}"

        def build_cte():
            if not has_custom_aggs or len(group_by) == 0:
                return None

            cte_parts = []
            for col, agg_name in columns_with_custom_aggs.items():
                custom_agg = self.custom_aggregates[agg_name]
                cte_parts.append(custom_agg.build_cte(col, col_name, group_by, table_name))

            return "WITH " + ",\n".join(cte_parts) if cte_parts else None

        def build_custom_select(col_name_fn=None):
            if not has_custom_aggs or len(group_by) == 0:
                return None

            if col_name_fn is None:
                col_name_fn = col_name

            custom_selects = []
            for col, agg_name in columns_with_custom_aggs.items():
                custom_agg = self.custom_aggregates[agg_name]
                custom_selects.append(custom_agg.build_select(col, col_name_fn, group_by))
            return custom_selects

        if has_custom_aggs and len(group_by) > 0 and len(split_by) == 0:
            cte = build_cte()

            # Check if we have mixed custom/primitive aggregates (will need JOIN)
            has_non_custom_cols = any(col not in columns_with_custom_aggs for col in columns)

            custom_selects = build_custom_select()

            if cte and custom_selects:
                groups = ", ".join(col_name(x) for x in group_by)
                first_col = next(iter(columns_with_custom_aggs))
                first_agg = self.custom_aggregates[columns_with_custom_aggs[first_col]]
                cte_name = f"{first_col}_{first_agg.cte_suffix}"

                cte_names = {}
                for col, agg_name in columns_with_custom_aggs.items():
                    custom_agg = self.custom_aggregates[agg_name]
                    cte_names[col] = f"{col}_{custom_agg.cte_suffix}"

                final_selects = []
                for col in columns:
                    if col in columns_with_custom_aggs:
                        final_selects.append(custom_selects.pop(0) if custom_selects else "")
                    else:
                        final_selects.append(f'{aggregates.get(col)}({col_name(col)}) as "{col}"')

                final_selects.extend(f"{col_name(group)} as __ROW_PATH_{idx}__" for idx, group in enumerate(group_by))
                final_selects.append(f"GROUPING_ID({groups}) AS __GROUPING_ID__")

                where_parts = list(where_clause())
                where_str = f"WHERE {' AND '.join(where_parts)}" if where_parts else ""

                if has_non_custom_cols:
                    def cte_qualified_col_name(col):
                        expr = config["expressions"].get(col)
                        if expr:
                            return expr
                        return f'{cte_name}."{col}"'

                    custom_selects_fresh = build_custom_select(cte_qualified_col_name)

                    normal_agg_cte = f"{cte_name}_normal"
                    normal_selects = []
                    for col in columns:
                        if col not in columns_with_custom_aggs:
                            agg = aggregates.get(col)
                            if agg == "avg":
                                normal_selects.append(f'sum({col_name(col)}) as "{col}__sum"')
                                normal_selects.append(f'count({col_name(col)}) as "{col}__count"')
                            else:
                                normal_selects.append(f'{agg}({col_name(col)}) as "{col}"')

                    normal_agg_query = f"""
                    ,
                    {normal_agg_cte} AS (
                        SELECT
                            {", ".join(col_name(g) for g in group_by)},
                            {", ".join(normal_selects)}
                        FROM {table_name}
                        {where_str}
                        GROUP BY {", ".join(col_name(g) for g in group_by)}
                    )
                    """

                    join_conditions = " AND ".join(
                        f"{cte_name}.{col_name(g)} = {normal_agg_cte}.{col_name(g)}"
                        for g in group_by
                    )

                    final_selects_joined = []
                    for col in columns:
                        if col in columns_with_custom_aggs:
                            final_selects_joined.append(custom_selects_fresh.pop(0))
                        else:
                            agg_func = aggregates.get(col)
                            if agg_func == "avg":
                                final_selects_joined.append(
                                    f'sum({normal_agg_cte}."{col}__sum") / sum({normal_agg_cte}."{col}__count") as "{col}"'
                                )
                            else:
                                # Map basic aggregates to rollup equivalents
                                rollup_agg_map = {"count": "sum"}
                                rollup_agg = rollup_agg_map.get(agg_func, agg_func)
                                final_selects_joined.append(f'{rollup_agg}({normal_agg_cte}."{col}") as "{col}"')

                    final_selects_joined.extend(f"{cte_name}.{col_name(group)} as __ROW_PATH_{idx}__" for idx, group in enumerate(group_by))
                    final_selects_joined.append(f"GROUPING_ID({', '.join(f'{cte_name}.{col_name(g)}' for g in group_by)}) AS __GROUPING_ID__")

                    # Build ORDER BY with CTE-qualified names
                    order_by_parts = []
                    for gidx in range(len(group_by)):
                        groups_prefixed = ", ".join(f'{cte_name}.{col_name(g)}' for g in group_by[: (gidx + 1)])
                        order_by_parts.append(f"GROUPING_ID({groups_prefixed}) DESC")

                        for sort_col, sort_dir in sort:
                            if sort_dir != "none" and gidx >= len(group_by) - 1:
                                # Reference the computed column directly
                                order_by_parts.append(f'"{sort_col}" {sort_dir}')

                        order_by_parts.append(f"__ROW_PATH_{gidx}__ ASC")

                    order_str = f"ORDER BY {', '.join(order_by_parts)}" if order_by_parts else ""

                    query = f"""
                    {cte}
                    {normal_agg_query}
                    SELECT {", ".join(final_selects_joined)}
                    FROM {cte_name}
                    INNER JOIN {normal_agg_cte} ON {join_conditions}
                    GROUP BY ROLLUP({", ".join(f'{cte_name}.{col_name(g)}' for g in group_by)})
                    {order_str}
                    """
                else:
                    if len(cte_names) > 1:
                        custom_selects_joined = []
                        cte_list = list(cte_names.values())
                        first_cte = cte_list[0]

                        def make_col_name_fn(target_col, target_cte):
                            def col_name_fn(c):
                                expr = config["expressions"].get(c)
                                if expr:
                                    return expr
                                if c == target_col:
                                    return f'{target_cte}."{c}"'
                                return f'{first_cte}."{c}"'
                            return col_name_fn

                        for col, agg_name in columns_with_custom_aggs.items():
                            custom_agg = self.custom_aggregates[agg_name]
                            col_name_fn = make_col_name_fn(col, cte_names[col])
                            custom_selects_joined.append(custom_agg.build_select(col, col_name_fn, group_by))

                        join_clauses = []
                        for other_cte in cte_list[1:]:
                            join_conditions = " AND ".join(
                                f"{first_cte}.{col_name(g)} = {other_cte}.{col_name(g)}"
                                for g in group_by
                            )
                            join_clauses.append(f"INNER JOIN {other_cte} ON {join_conditions}")

                        final_selects_joined = custom_selects_joined.copy()
                        final_selects_joined.extend(f"{first_cte}.{col_name(group)} as __ROW_PATH_{idx}__" for idx, group in enumerate(group_by))
                        final_selects_joined.append(f"GROUPING_ID({', '.join(f'{first_cte}.{col_name(g)}' for g in group_by)}) AS __GROUPING_ID__")

                        order_by_parts = []
                        for gidx in range(len(group_by)):
                            groups_prefixed = ", ".join(f'{first_cte}.{col_name(g)}' for g in group_by[: (gidx + 1)])
                            order_by_parts.append(f"GROUPING_ID({groups_prefixed}) DESC")

                            for sort_col, sort_dir in sort:
                                if sort_dir != "none" and gidx >= len(group_by) - 1:
                                    order_by_parts.append(f'"{sort_col}" {sort_dir}')

                            order_by_parts.append(f"__ROW_PATH_{gidx}__ ASC")

                        order_str = f"ORDER BY {', '.join(order_by_parts)}" if order_by_parts else ""

                        query = f"""
                        {cte}
                        SELECT {", ".join(final_selects_joined)}
                        FROM {first_cte}
                        {" ".join(join_clauses)}
                        GROUP BY ROLLUP({", ".join(f'{first_cte}.{col_name(g)}' for g in group_by)})
                        {order_str}
                        """
                    else:
                        # Single custom CTE - no join needed
                        order_by_parts = []
                        for gidx in range(len(group_by)):
                            groups_prefixed = ", ".join(col_name(g) for g in group_by[: (gidx + 1)])
                            order_by_parts.append(f"GROUPING_ID({groups_prefixed}) DESC")

                            for sort_col, sort_dir in sort:
                                if sort_dir != "none" and gidx >= len(group_by) - 1:
                                    order_by_parts.append(f'"{sort_col}" {sort_dir}')

                            order_by_parts.append(f"__ROW_PATH_{gidx}__ ASC")

                        order_str = f"ORDER BY {', '.join(order_by_parts)}" if order_by_parts else ""

                        query = f"""
                        {cte}
                        SELECT {", ".join(final_selects)}
                        FROM {cte_name}
                        {where_str}
                        GROUP BY ROLLUP({groups})
                        {order_str}
                        """

                run_query(self.db, f"CREATE TEMPORARY TABLE {view_name} AS ({query})", execute=True)
                return

        query = f"SELECT * FROM {table_name}" if split_by else f"SELECT {', '.join(select_clause())} FROM {table_name}"

        if where := list(where_clause()):
            query = f"{query} WHERE {' AND '.join(where)}"

        if split_by:
            groups = ", ".join(col_name(x) for x in group_by)
            group_aliases = ", ".join(f"{col_name(x)} AS __ROW_PATH_{i}__" for i, x in enumerate(group_by))

            query = f"""
            SELECT * EXCLUDE ({groups}), {group_aliases} FROM (
                PIVOT ({query})
                ON {", ".join(f'"{c}"' for c in split_by)}
                USING {", ".join(select_clause())}
                GROUP BY {groups}
            )
            """
        elif group_by:
            query = f"{query} GROUP BY ROLLUP({', '.join(col_name(x) for x in group_by)})"

        if window := list(window_clause()):
            query = f"{query} WINDOW {', '.join(window)}"

        if order_by := list(order_by_clause()):
            query = f"{query} ORDER BY {', '.join(order_by)}"

        run_query(self.db, f"CREATE TEMPORARY TABLE {view_name} AS ({query})", execute=True)

    def table_validate_expression(self, view_name, expression):
        query = f"DESCRIBE (select {expression} from {view_name})"
        results = run_query(self.db, query)
        return duckdb_type_to_psp(results[0][1])

    def view_delete(self, view_name):
        query = f"DROP TABLE {view_name}"
        run_query(self.db, query, execute=True)

    def view_get_data(self, view_name, config, viewport, data):
        group_by = config["group_by"]
        split_by = config["split_by"]
        start_col = viewport.get("start_col")
        end_col = viewport.get("end_col")

        limit = ""
        if (end_row := viewport.get("end_row")) is not None:
            start_row = viewport.get("start_row", 0)
            limit = f"LIMIT {end_row - start_row} OFFSET {start_row}"

        col_limit = ""
        if end_col is not None:
            col_limit = f"LIMIT {end_col - start_col} OFFSET {start_col}"

        group_by_columns = ""
        if len(group_by) > 0:
            if len(split_by) == 0:
                row_paths = ["__GROUPING_ID__"]
            else:
                row_paths = []

            row_paths.extend(f"__ROW_PATH_{idx}__" for idx in range(len(group_by)))
            group_by_columns = f"{', '.join(row_paths)},"

        query = f"""
            SET VARIABLE col_names = (
                SELECT list(column_name) FROM (
                    SELECT column_name 
                    FROM (DESCRIBE {view_name})
                    WHERE not(starts_with(column_name, '__'))
                    {col_limit}
                )
            );

            SELECT
                {group_by_columns}
                COLUMNS(c -> list_contains(getvariable('col_names'), c))
            FROM {view_name} {limit}
        """

        results, columns, dtypes = run_query(self.db, query, columns=True)
        for cidx, col in enumerate(columns):
            if cidx == 0 and len(group_by) > 0 and len(split_by) == 0:
                continue

            group_by_index = None
            max_grouping_id = None
            if len(prefix := col.split("__ROW_PATH_")) > 1:
                group_by_index = int(prefix[1].split("__")[0])
                max_grouping_id = 2 ** (len(group_by) - group_by_index) - 1

            for ridx, row in enumerate(results):
                dtype = duckdb_type_to_psp(dtypes[cidx])
                if (
                    len(split_by) > 0
                    or max_grouping_id is None
                    or row[0] < max_grouping_id
                ):
                    data.set_col(
                        dtype,
                        col.replace("_", "|"),
                        ridx,
                        row[cidx],
                        group_by_index=group_by_index,
                    )


################################################################################
#
# DuckDB Utils


def val_to_duckdb_lit(value):
    """
    Convert a Python value to a string representation of this values suitable
    for SQL injecting.
    """
    if isinstance(value, str):
        return f"'{value}'"
    return str(value)


def sort_to_duckdb_sort(sortdir):
    if sortdir == "asc":
        return "ASC"
    if sortdir == "desc":
        return "DESC"
    return "DESC"


def duckdb_type_to_psp(name):
    """Convert a DuckDB `dtype` to a Perspective `ColumnType`."""
    if name == "VARCHAR":
        return "string"
    if name in ("DOUBLE", "BIGINT", "HUGEINT"):
        return "float"
    if name == "INTEGER":
        return "integer"
    if name == "DATE":
        return "date"
    if name == "BOOLEAN":
        return "boolean"
    if name == "TIMESTAMP":
        return "datetime"

    msg = f"Unknown type '{name}'"
    raise ValueError(msg)


def run_query(db, query, execute=False, columns=False):
    query = " ".join(query.split())
    start = datetime.now()
    result = None
    try:
        if execute:
            db.execute(query)
        else:
            req = db.sql(query)
            result = req.fetchall()
    except (duckdb.ParserException, duckdb.BinderException) as e:
        logger.error(e)
        logger.error(f"{query}")
        raise e
    else:
        logger.debug(f"{datetime.now() - start} {query}")
        if columns:
            return (result, req.columns, req.dtypes)
        else:
            return result
