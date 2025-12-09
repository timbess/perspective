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
from typing import List

from perspective.virtual_servers import VirtualSessionModel
from perspective.virtual_servers.sql_builder import (
    BinaryOp, BinaryOperator, CTE, ColumnRef, Pivot,
    Expr, JoinType, Select, SelectColumn, SortDir, TableRef,
    col as col_ref, count_all, create_table, cte as make_cte, describe, drop_table, func,
    join as make_join, lit, query_with_ctes, raw, select_col, tableref, window, order_by
)

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
    def __init__(self, underlying_type: CustomAggregateType, cte_suffix: str):
        self.underlying_type = underlying_type
        self.cte_suffix = cte_suffix

    @abstractmethod
    def build_cte(self, cte_name: str, col: ColumnRef, group_by: List[ColumnRef], table: TableRef) -> List[CTE]:
        pass

    @abstractmethod
    def build_select(self, cte_table: TableRef, col: ColumnRef, group_by: List[ColumnRef]) -> SelectColumn:
        pass

class DuckDBVirtualSession:
    def __init__(self, callback, db, custom_aggregates=None):
        self.session = perspective.VirtualServer(
            DuckDBVirtualSessionModel(db, custom_aggregates)
        )
        self.callback = callback

    def handle_request(self, msg):
        self.callback(self.session.handle_request(msg))

    def close(self):
        pass


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
        query = describe(table_name).to_sql()
        results = run_query(self.db, query)
        return {
            result[0].split("_")[-1]: duckdb_type_to_psp(result[1])
            for result in results
            if not (result[0].startswith("__") and result[0].endswith("__"))
        }

    def table_columns_size(self, table_name, config):
        # TODO split this into 2 methods
        desc_query = describe(table_name).to_sql()
        query_obj = Select(
            columns=[select_col(count_all())],
            from_table=f"({desc_query})"
        )
        results = run_query(self.db, query_obj.to_sql())
        gs = len(config["group_by"])
        return results[0][0] - (
            0 if gs == 0 else gs + (1 if len(config["split_by"]) == 0 else 0)
        )

    def table_size(self, table_name):
        query_obj = Select(
            columns=[select_col(count_all())],
            from_table=table_name
        )
        results = run_query(self.db, query_obj.to_sql())
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

        def resolve_col(col_name_str: str, table: TableRef = None) -> Expr:
            expr = config["expressions"].get(col_name_str)
            if expr:
                return raw(expr)
            if table:
                return table.col(col_name_str)
            return col_ref(col_name_str)

        def where_clause():
            for name, op, value in config["filter"]:
                if value is not None:
                    yield BinaryOp(resolve_col(name), str_to_operator(op), lit(value))

        if columns_with_custom_aggs and group_by and not split_by:
            query = self._build_custom_agg_query(
                table_name, columns, group_by, columns_with_custom_aggs,
                aggregates, where_clause, resolve_col, sort
            )
            run_query(self.db, create_table(view_name, query, temporary=True).to_sql(), execute=True)
            return

        where_exprs = list(where_clause())

        if split_by:
            query = Select(
                columns=["*"],
                exclude=[resolve_col(c) for c in group_by],
                from_table=Pivot(
                    Select(columns=["*"], from_table=table_name, where=where_exprs or None),
                    on=[resolve_col(c) for c in split_by],
                    using=[select_col(func(aggregates.get(c), resolve_col(c)), c) for c in columns],
                    group_by=[resolve_col(g) for g in group_by]
                )
            )
            run_query(self.db, create_table(view_name, query, temporary=True).to_sql(), execute=True)
        else:
            select_cols = []
            if group_by:
                for col in columns:
                    select_cols.append(select_col(func(aggregates.get(col), resolve_col(col)), col))
                for idx, group in enumerate(group_by):
                    select_cols.append(select_col(resolve_col(group), f"__ROW_PATH_{idx}__"))
                select_cols.append(select_col(func("GROUPING_ID", *[resolve_col(g) for g in group_by]), "__GROUPING_ID__"))
            else:
                for col in columns:
                    select_cols.append(select_col(resolve_col(col), col.replace('"', '""')))

            order_by_tuples = []
            if group_by:
                for gidx in range(len(group_by)):
                    group_slice = [resolve_col(g) for g in group_by[: (gidx + 1)]]
                    order_by_tuples.append((func("GROUPING_ID", *group_slice), SortDir.DESC))

                    for sort_col, sort_dir in sort:
                        if sort_dir != "none":
                            agg = aggregates.get(sort_col)
                            if gidx >= len(group_by) - 1:
                                order_by_tuples.append((func(agg, resolve_col(sort_col)), SortDir.DESC if sort_dir == "desc" else SortDir.ASC))
                            else:
                                window_expr = func("first", func(agg, resolve_col(sort_col)))
                                order_by_tuples.append((raw(f"{window_expr.to_sql()} OVER __WINDOW_{gidx}__"), SortDir.DESC if sort_dir == "desc" else SortDir.ASC))

                    order_by_tuples.append((col_ref(f"__ROW_PATH_{gidx}__"), SortDir.ASC))
            else:
                for sort_col, sort_dir in sort:
                    if sort_dir:
                        order_by_tuples.append((resolve_col(sort_col), SortDir.DESC if sort_dir == "desc" else SortDir.ASC))

            window_clauses = []
            if sort and group_by:
                for gidx in range(len(group_by) - 1):
                    partitions = [col_ref(f"__ROW_PATH_{i}__") for i in range(gidx + 1)]
                    sub_groups = [resolve_col(g) for g in group_by[: (gidx + 1)]]
                    groups_order = [order_by(resolve_col(g)) for g in group_by]
                    window_clauses.append(window(
                        col_ref(f"__WINDOW_{gidx}__"),
                        partition_by=[func("GROUPING_ID", *sub_groups), *partitions],
                        order_by=groups_order
                    ))

            query_obj = Select(
                columns=select_cols,
                from_table=table_name,
                where=where_exprs or None,
                group_by=[resolve_col(g) for g in group_by] if group_by else None,
                group_by_rollup=bool(group_by),
                order_by=order_by_tuples or None,
                window=window_clauses or None,
            )

            run_query(self.db, create_table(view_name, query_obj, temporary=True).to_sql(), execute=True)

    def _build_custom_agg_query(self, table_name, columns, group_by, columns_with_custom_aggs,
                                aggregates, where_clause, resolve_col, sort):
        def build_rollup_order_by(table_ref: TableRef = None):
            for gidx in range(len(group_by)):
                group_slice = [resolve_col(g, table_ref) for g in group_by[: (gidx + 1)]]
                yield (func("GROUPING_ID", *group_slice), SortDir.DESC)
                for sort_col, sort_dir in sort:
                    if sort_dir != "none" and gidx >= len(group_by) - 1:
                        yield (col_ref(sort_col), SortDir.DESC if sort_dir == "desc" else SortDir.ASC)
                yield (col_ref(f"__ROW_PATH_{gidx}__"), SortDir.ASC)

        def add_metadata_columns(cols, table_ref):
            for i, g in enumerate(group_by):
                cols.append(select_col(table_ref.col(g), f"__ROW_PATH_{i}__"))
            cols.append(select_col(func("GROUPING_ID", *[table_ref.col(g) for g in group_by]), "__GROUPING_ID__"))

        def build_join_conditions(left_table, right_table):
            conditions = [left_table.col(g).eq(right_table.col(g)) for g in group_by]
            result = conditions[0]
            for cond in conditions[1:]:
                result = BinaryOp(result, BinaryOperator.AND, cond)
            return result

        ctes = []
        for col_name, agg_name in columns_with_custom_aggs.items():
            custom_agg = self.custom_aggregates[agg_name]
            cte_name = f"{col_name}_{custom_agg.cte_suffix}"
            ctes.extend(custom_agg.build_cte(
                cte_name,
                resolve_col(col_name),
                [resolve_col(g) for g in group_by],
                tableref(table_name)
            ))

        cte_map = {col: tableref(f"{col}_{self.custom_aggregates[agg].cte_suffix}")
                   for col, agg in columns_with_custom_aggs.items()}
        first_cte = next(iter(cte_map.values()))
        has_normal_aggs = any(col not in columns_with_custom_aggs for col in columns)

        if has_normal_aggs:
            where_exprs = list(where_clause())
            normal_cte_name = f"{first_cte.name}_normal"
            normal_cols = [select_col(resolve_col(g)) for g in group_by]
            for col in columns:
                if col not in columns_with_custom_aggs:
                    agg = aggregates.get(col)
                    if agg == "avg":
                        normal_cols.append(select_col(func("sum", resolve_col(col)), f"{col}__sum"))
                        normal_cols.append(select_col(func("count", resolve_col(col)), f"{col}__count"))
                    else:
                        normal_cols.append(select_col(func(agg, resolve_col(col)), col))

            ctes.append(make_cte(normal_cte_name, normal_cols, table_name,
                                 where=where_exprs or None, group_by=[resolve_col(g) for g in group_by]))

            final_cols = []
            for col in columns:
                if col in columns_with_custom_aggs:
                    custom_agg = self.custom_aggregates[columns_with_custom_aggs[col]]
                    cte_table = cte_map[col]
                    final_cols.append(custom_agg.build_select(
                        cte_table, cte_table.col(col), [first_cte.col(g) for g in group_by]
                    ))
                else:
                    agg = aggregates.get(col)
                    normal_table = tableref(normal_cte_name)
                    if agg == "avg":
                        final_cols.append(select_col(
                            BinaryOp(func("sum", normal_table.col(f"{col}__sum")),
                                   BinaryOperator.DIV,
                                   func("count", normal_table.col(f"{col}__count"))), col))
                    else:
                        rollup_agg = "sum" if agg == "count" else agg
                        final_cols.append(select_col(func(rollup_agg, normal_table.col(col)), col))

            add_metadata_columns(final_cols, first_cte)
            joins = [make_join(normal_cte_name, build_join_conditions(first_cte, tableref(normal_cte_name)), JoinType.INNER)]
            select_obj = Select(
                columns=final_cols,
                from_table=first_cte.name,
                joins=joins,
                group_by=[first_cte.col(g) for g in group_by],
                group_by_rollup=True,
                order_by=list(build_rollup_order_by(first_cte)) or None
            )

        elif len(cte_map) > 1:
            final_cols = []
            for col, agg_name in columns_with_custom_aggs.items():
                custom_agg = self.custom_aggregates[agg_name]
                cte_table = cte_map[col]
                final_cols.append(custom_agg.build_select(
                    cte_table, cte_table.col(col), [first_cte.col(g) for g in group_by]
                ))

            add_metadata_columns(final_cols, first_cte)
            joins = [make_join(cte.name, build_join_conditions(first_cte, cte), JoinType.INNER)
                     for cte in list(cte_map.values())[1:]]
            select_obj = Select(
                columns=final_cols,
                from_table=first_cte.name,
                joins=joins,
                group_by=[first_cte.col(g) for g in group_by],
                group_by_rollup=True,
                order_by=list(build_rollup_order_by(first_cte)) or None
            )

        else:
            where_exprs = list(where_clause())
            final_cols = []
            for col in columns:
                if col in columns_with_custom_aggs:
                    custom_agg = self.custom_aggregates[columns_with_custom_aggs[col]]
                    final_cols.append(custom_agg.build_select(
                        first_cte, resolve_col(col), [resolve_col(g) for g in group_by]
                    ))
                else:
                    final_cols.append(select_col(func(aggregates.get(col), resolve_col(col)), col))

            for idx, g in enumerate(group_by):
                final_cols.append(select_col(resolve_col(g), f"__ROW_PATH_{idx}__"))
            final_cols.append(select_col(func("GROUPING_ID", *[resolve_col(g) for g in group_by]), "__GROUPING_ID__"))

            select_obj = Select(
                columns=final_cols,
                from_table=first_cte.name,
                where=where_exprs or None,
                group_by=[resolve_col(g) for g in group_by],
                group_by_rollup=True,
                order_by=list(build_rollup_order_by()) or None
            )

        return query_with_ctes(ctes, select_obj).to_sql()

    def table_validate_expression(self, view_name, expression):
        select_query = Select(
            columns=[raw(expression)],
            from_table=view_name
        )
        query = describe(select_query).to_sql()
        results = run_query(self.db, query)
        return duckdb_type_to_psp(results[0][1])

    def view_delete(self, view_name):
        query = drop_table(view_name).to_sql()
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

def str_to_operator(op_str: str) -> BinaryOperator:
    op_map = {
        "==": BinaryOperator.EQ,
        "!=": BinaryOperator.NE,
        "<": BinaryOperator.LT,
        "<=": BinaryOperator.LE,
        ">": BinaryOperator.GT,
        ">=": BinaryOperator.GE,
        "LIKE": BinaryOperator.LIKE,
        "IS DISTINCT FROM": BinaryOperator.IS_DISTINCT_FROM,
        "IS NOT DISTINCT FROM": BinaryOperator.IS_NOT_DISTINCT_FROM,
    }
    if op_str not in op_map:
        raise ValueError(f"Unknown operator: {op_str}")
    return op_map[op_str]


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
