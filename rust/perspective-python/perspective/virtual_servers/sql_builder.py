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

from dataclasses import dataclass, field
from typing import List, Optional, override
from abc import ABC, abstractmethod
from enum import Enum

class SortDir(Enum):
    ASC = "ASC"
    DESC = "DESC"

class JoinType(Enum):
    INNER = "INNER JOIN"
    LEFT = "LEFT JOIN"
    RIGHT = "RIGHT JOIN"
    FULL = "FULL OUTER JOIN"
    CROSS = "CROSS JOIN"

class BinaryOperator(Enum):
    EQ = "="
    NE = "!="
    LT = "<"
    LE = "<="
    GT = ">"
    GE = ">="
    AND = "AND"
    OR = "OR"
    PLUS = "+"
    MINUS = "-"
    MULTIPLY = "*"
    DIVIDE = "/"
    LIKE = "LIKE"
    IS_DISTINCT_FROM = "IS DISTINCT FROM"
    IS_NOT_DISTINCT_FROM = "IS NOT DISTINCT FROM"


class TableRef:
    def __init__(self, name: str):
        self.name = name

    def col(self, column_name: str, quoted: bool = True) -> "ColumnRef":
        return ColumnRef(column_name, quoted, self.name)


class Expr(ABC):
    @abstractmethod
    def to_sql(self) -> str:
        """Convert this expression to SQL string."""
        pass


@dataclass
class ColumnRef(Expr):
    name: str
    quoted: bool = True
    table: Optional[str] = None

    @override
    def to_sql(self) -> str:
        col_name = f'"{self.name}"' if self.quoted else self.name
        if self.table:
            return f'"{self.table}".{col_name}'
        return col_name

    def eq(self, other: "Expr | int | str | float") -> "BinaryOp":
        right = Literal(other) if not isinstance(other, Expr) else other
        return BinaryOp(self, BinaryOperator.EQ, right)

    def ne(self, other: "Expr | int | str | float") -> "BinaryOp":
        right = Literal(other) if not isinstance(other, Expr) else other
        return BinaryOp(self, BinaryOperator.NE, right)

    def lt(self, other: "Expr | int | str | float") -> "BinaryOp":
        right = Literal(other) if not isinstance(other, Expr) else other
        return BinaryOp(self, BinaryOperator.LT, right)

    def le(self, other: "Expr | int | str | float") -> "BinaryOp":
        right = Literal(other) if not isinstance(other, Expr) else other
        return BinaryOp(self, BinaryOperator.LE, right)

    def gt(self, other: "Expr | int | str | float") -> "BinaryOp":
        right = Literal(other) if not isinstance(other, Expr) else other
        return BinaryOp(self, BinaryOperator.GT, right)

    def ge(self, other: "Expr | int | str | float") -> "BinaryOp":
        right = Literal(other) if not isinstance(other, Expr) else other
        return BinaryOp(self, BinaryOperator.GE, right)


@dataclass
class RawExpr(Expr):
    sql: str

    @override
    def to_sql(self) -> str:
        return self.sql


@dataclass
class BinaryOp(Expr):
    left: Expr
    operator: BinaryOperator
    right: Expr

    @override
    def to_sql(self) -> str:
        return f"{self.left.to_sql()} {self.operator.value} {self.right.to_sql()}"


@dataclass
class Literal(Expr):
    value: any

    @override
    def to_sql(self) -> str:
        if isinstance(self.value, str):
            return f"'{self.value}'"
        return str(self.value)


@dataclass
class Function(Expr):
    name: str
    args: List[Expr] = field(default_factory=list)

    @override
    def to_sql(self) -> str:
        args_sql = ", ".join(arg.to_sql() for arg in self.args)
        return f"{self.name}({args_sql})"


@dataclass
class WindowFunction(Expr):
    function: Function | ColumnRef
    partition_by: List[Expr] = field(default_factory=list)
    order_by: List[tuple[Expr, SortDir]] = field(default_factory=list)
    frame: Optional[str] = None  # e.g., "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW"

    @override
    def to_sql(self) -> str:
        over_parts = []

        if self.partition_by:
            partition_sql = ", ".join(expr.to_sql() for expr in self.partition_by)
            over_parts.append(f"PARTITION BY {partition_sql}")

        if self.order_by:
            order_sql = ", ".join(f"{expr.to_sql()} {direction.value}" for expr, direction in self.order_by)
            over_parts.append(f"ORDER BY {order_sql}")

        if self.frame:
            over_parts.append(self.frame)

        over_clause = " ".join(over_parts) if over_parts else ""
        return f"{self.function.to_sql()} OVER ({over_clause})"


@dataclass
class CaseWhen(Expr):
    condition: Expr
    then: Expr

    @override
    def to_sql(self) -> str:
        return f"WHEN {self.condition.to_sql()} THEN {self.then.to_sql()}"

@dataclass
class Case(Expr):
    when_clauses: List[CaseWhen] = field(default_factory=list)
    else_clause: Optional[Expr] = None

    @override
    def to_sql(self) -> str:
        parts = ["CASE"]

        for when in self.when_clauses:
            parts.append(when.to_sql())

        if self.else_clause:
            parts.append(f"ELSE {self.else_clause.to_sql()}")

        parts.append("END")
        return "\n                ".join(parts)


@dataclass
class SelectColumn(Expr):
    expr: Expr
    alias: Optional[str] = None

    @override
    def to_sql(self) -> str:
        sql = self.expr.to_sql()
        if self.alias:
            return f'{sql} AS "{self.alias}"'
        return sql


@dataclass
class CTE(Expr):
    name: str
    columns: List[SelectColumn]
    from_table: str
    where: Optional[List[Expr]] = None
    group_by: Optional[List[Expr]] = None

    @override
    def to_sql(self) -> str:
        columns_sql = ",\n                    ".join(col.to_sql() for col in self.columns)

        parts = [
            f"{self.name} AS (",
            f"    SELECT",
            f"        {columns_sql}",
            f"    FROM {self.from_table}",
        ]

        if self.where:
            where_sql = " AND ".join(expr.to_sql() for expr in self.where)
            parts.append(f"    WHERE {where_sql}")

        if self.group_by:
            group_sql = ", ".join(expr.to_sql() for expr in self.group_by)
            parts.append(f"    GROUP BY {group_sql}")

        parts.append(")")

        return "\n            ".join(parts)

def col(name: str, quoted: bool = True, table: str = None) -> ColumnRef:
    return ColumnRef(name, quoted, table)

def raw(sql: str) -> RawExpr:
    return RawExpr(sql)

def func(name: str, *args: Expr) -> Function:
    return Function(name, list(args))

def sum_(*args: Expr) -> Function:
    return Function("sum", list(args))

def count(*args: Expr) -> Function:
    return Function("count", list(args))

def count_all() -> Function:
    return Function("count", [RawExpr("*")])

def max_(*args: Expr) -> Function:
    return Function("max", list(args))

def abs_(*args: Expr) -> Function:
    return Function("ABS", list(args))

def grouping(*args: Expr) -> Function:
    return Function("GROUPING", list(args))

def grouping_id(*args: Expr) -> Function:
    return Function("GROUPING_ID", list(args))

def row_number() -> Function:
    return Function("ROW_NUMBER", [])

def window(func: Function | ColumnRef, partition_by: List[Expr] = None, order_by: List[tuple[Expr, SortDir]] = None, frame: str = None) -> WindowFunction:
    return WindowFunction(
        function=func,
        partition_by=partition_by or [],
        order_by=order_by or [],
        frame=frame
    )

def case(*when_clauses: CaseWhen, else_clause: Expr = None) -> Case:
    return Case(list(when_clauses), else_clause)

def when(condition: Expr, then: Expr) -> CaseWhen:
    return CaseWhen(condition, then)

def select_col(expr: Expr, alias: str = None) -> SelectColumn:
    return SelectColumn(expr, alias)

def cte(name: str, columns: List[SelectColumn], from_table: str, where: List[Expr] = None, group_by: List[Expr] = None) -> CTE:
    return CTE(name, columns, from_table, where, group_by)

def tableref(name: str) -> TableRef:
    return TableRef(name)

def lit(value: any) -> Literal:
    return Literal(value)

def eq(left: Expr, right: Expr | int | str | float) -> BinaryOp:
    right_expr = lit(right) if not isinstance(right, Expr) else right
    return BinaryOp(left, BinaryOperator.EQ, right_expr)

def order_by(expr: Expr, direction: SortDir = SortDir.ASC) -> tuple[Expr, SortDir]:
    return (expr, direction)


@dataclass
class Join(Expr):
    join_type: JoinType
    table: str
    condition: Expr

    def to_sql(self) -> str:
        return f"{self.join_type.value} {self.table} ON {self.condition.to_sql()}"


@dataclass
class Select(Expr):
    columns: List[SelectColumn | RawExpr | str]
    from_table: str | Expr
    joins: List[Join] = field(default_factory=list)
    where: Optional[List[Expr]] = None
    group_by: Optional[List[Expr]] = None
    group_by_rollup: bool = False
    order_by: Optional[List[tuple[Expr, SortDir]]] = None
    limit: Optional[int] = None
    offset: Optional[int] = None
    window: Optional[List[WindowFunction]] = None
    exclude: List[ColumnRef | str] = field(default_factory=list)

    def to_sql(self) -> str:
        columns_sql = ", ".join(
            col.to_sql() if isinstance(col, Expr) else col
            for col in self.columns
        )

        parts = []
        parts.append(f"SELECT {columns_sql}")
        if self.exclude:
            if self.columns != ["*"]:
                raise ValueError("EXCLUDE can only be used with SELECT *")
            exclude_sql = ", ".join(
                col.to_sql() if isinstance(col, ColumnRef) else col
                for col in self.exclude
            )
            parts.append(f"EXCLUDE {exclude_sql}")

        if isinstance(self.from_table, Expr):
            parts.append(f"FROM ({self.from_table.to_sql()})")
        else:
            parts.append(f"FROM {self.from_table}")

        if self.joins:
            parts.extend(join.to_sql() for join in self.joins)

        if self.where:
            where_sql = " AND ".join(expr.to_sql() for expr in self.where)
            parts.append(f"WHERE {where_sql}")

        if self.group_by:
            group_sql = ", ".join(expr.to_sql() for expr in self.group_by)
            if self.group_by_rollup:
                parts.append(f"GROUP BY ROLLUP({group_sql})")
            else:
                parts.append(f"GROUP BY {group_sql}")

        if self.window:
            window_clauses = ', '.join(w.to_sql() for w in self.window)
            parts.append(f"WINDOW {window_clauses}")

        if self.order_by:
            order_sql = ", ".join(
                f"{expr.to_sql()} {direction.value}" for expr, direction in self.order_by
            )
            parts.append(f"ORDER BY {order_sql}")

        if self.limit is not None:
            parts.append(f"LIMIT {self.limit}")

        if self.offset is not None:
            parts.append(f"OFFSET {self.offset}")

        return " ".join(parts)


def join(table: str, condition: Expr, join_type: JoinType = JoinType.INNER) -> Join:
    return Join(join_type, table, condition)


def select(
    columns: List[SelectColumn | str],
    from_table: str,
    where: List[Expr] = None,
    group_by: List[Expr] = None,
    order_by: List[tuple[Expr, SortDir]] = None,
    limit: int = None,
    offset: int = None,
) -> Select:
    return Select(columns, from_table, where=where, group_by=group_by, order_by=order_by, limit=limit, offset=offset)


@dataclass
class QueryWithCTEs(Expr):
    ctes: List[CTE]
    select: Select

    def to_sql(self) -> str:
        if not self.ctes:
            return self.select.to_sql()

        cte_sql = ",\n".join(cte.to_sql() for cte in self.ctes)
        return f"WITH {cte_sql}\n{self.select.to_sql()}"


def query_with_ctes(ctes: List[CTE], select_query: Select) -> QueryWithCTEs:
    return QueryWithCTEs(ctes, select_query)


@dataclass
class Describe(Expr):
    target: str | Select

    def to_sql(self) -> str:
        if isinstance(self.target, Select):
            return f"DESCRIBE ({self.target.to_sql()})"
        return f"DESCRIBE {self.target}"


@dataclass
class DropTable(Expr):
    table_name: str
    if_exists: bool = False

    def to_sql(self) -> str:
        exists_clause = "IF EXISTS " if self.if_exists else ""
        return f"DROP TABLE {exists_clause}{self.table_name}"


@dataclass
class CreateTable(Expr):
    table_name: str
    query: Expr | str
    temporary: bool = False

    def to_sql(self) -> str:
        temp_clause = "TEMPORARY " if self.temporary else ""
        if isinstance(self.query, Expr):
            query_sql = self.query.to_sql()
        else:
            query_sql = self.query
        return f"CREATE {temp_clause}TABLE {self.table_name} AS ({query_sql})"


def describe(target: str | Select) -> Describe:
    return Describe(target)


def drop_table(table_name: str, if_exists: bool = False) -> DropTable:
    return DropTable(table_name, if_exists)


def create_table(table_name: str, query: Expr | str, temporary: bool = False) -> CreateTable:
    return CreateTable(table_name, query, temporary)


@dataclass
class Pivot(Expr):
    select: Select
    on: List[Expr]
    using: List[SelectColumn]
    group_by: List[Expr]

    def to_sql(self) -> str:
        parts =[f"PIVOT ({self.select.to_sql()})"]
        if not self.on:
            raise ValueError("PIVOT requires at least one ON expression")
        parts.append("ON " + ", ".join(expr.to_sql() for expr in self.on))

        if not self.using:
            raise ValueError("PIVOT requires at least one USING column")
        parts.append("USING " + ", ".join(col.to_sql() for col in self.using))

        if self.group_by:
            parts.append("GROUP_BY " + ", ".join(expr.to_sql() for expr in self.group_by))

        return " ".join(parts)


def pivot(select: Select, on: List[Expr], using: List[SelectColumn], group_by: List[Expr]) -> Pivot:
    return Pivot(select, on, using, group_by)