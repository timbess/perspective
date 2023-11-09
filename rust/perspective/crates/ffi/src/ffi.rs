use std::borrow::BorrowMut;
use std::sync::Arc;

use cxx::let_cxx_string;
use cxx::{SharedPtr, UniquePtr};
use std::pin::Pin;
use wasm_bindgen::{prelude::*, JsObject};

#[cxx::bridge(namespace = ffi)]
mod ffi_internal {

    #[derive(Debug, Eq, PartialEq)]
    #[repr(u8)]
    enum DType {
        DTYPE_NONE,
        DTYPE_INT64,
        DTYPE_INT32,
        DTYPE_INT16,
        DTYPE_INT8,
        DTYPE_UINT64,
        DTYPE_UINT32,
        DTYPE_UINT16,
        DTYPE_UINT8,
        DTYPE_FLOAT64,
        DTYPE_FLOAT32,
        DTYPE_BOOL,
        DTYPE_TIME,
        DTYPE_DATE,
        DTYPE_ENUM,
        DTYPE_OID,
        DTYPE_OBJECT,
        DTYPE_F64PAIR,
        DTYPE_USER_FIXED,
        DTYPE_STR,
        DTYPE_USER_VLEN,
        DTYPE_LAST_VLEN,
        DTYPE_LAST,
    }

    unsafe extern "C++" {
        include!("perspective-ffi/cpp/ffi.h");
        include!("perspective-ffi/cpp/types.h");

        type Pool;
        type Table;
        type GNode;
        type DataTable;
        type Column;
        type Schema;

        pub fn size(self: &Table) -> usize;
        pub fn get_gnode(self: &Table) -> SharedPtr<GNode>;
        pub fn make_table_port(table: &Table) -> usize;

        pub fn get_table_schema(table: &Table) -> UniquePtr<Schema>;

        pub fn get_schema_columns(schema: &Schema) -> Vec<String>;
        pub fn get_schema_types(schema: &Schema) -> Vec<DType>;

        pub fn get_table_sptr(self: &GNode) -> SharedPtr<DataTable>;
        pub fn process_gnode(gnode: &GNode, idx: usize) -> bool;

        pub fn get_column(self: &DataTable, name: &CxxString) -> SharedPtr<Column>;

        pub fn get_col_dtype(col: &Column) -> DType;
        pub fn get_col_nth_u32(col: &Column, idx: usize) -> u32;
        pub fn get_col_nth_u64(col: &Column, idx: usize) -> u64;
        pub fn get_col_nth_i32(col: &Column, idx: usize) -> i32;
        pub fn get_col_nth_i64(col: &Column, idx: usize) -> i64;
        pub fn pretty_print(table: &Table, num_rows: usize) -> String;

        pub fn size(self: &Column) -> usize;

        pub fn mk_pool() -> UniquePtr<Pool>;

        pub fn mk_table(
            column_names: Vec<String>,
            data_types: Vec<DType>,
            limit: u32,
            index: String,
        ) -> SharedPtr<Table>;
    }
}
pub use ffi_internal::mk_pool;
pub use ffi_internal::mk_table;
pub use ffi_internal::DType;

// use crate::cpp_common::DType;

pub struct Pool {
    pool: UniquePtr<ffi_internal::Pool>,
}

impl Pool {
    pub fn new() -> Self {
        Pool {
            pool: ffi_internal::mk_pool(),
        }
    }
}

#[wasm_bindgen]
pub struct Column {
    column: SharedPtr<ffi_internal::Column>,
}

impl Column {
    pub fn get_dtype(&self) -> DType {
        ffi_internal::get_col_dtype(&self.column)
    }

    pub fn get_u32(&self, idx: usize) -> u32 {
        ffi_internal::get_col_nth_u32(&self.column, idx)
    }

    pub fn get_u64(&self, idx: usize) -> u64 {
        ffi_internal::get_col_nth_u64(&self.column, idx)
    }
}

#[wasm_bindgen]
impl Column {
    #[wasm_bindgen(js_name = "getDType")]
    pub fn get_dtype_string(&self) -> String {
        format!("{:?}", self.get_dtype())
    }

    #[wasm_bindgen(js_name = "getU32")]
    pub fn get_u32_js(&self, idx: usize) -> u32 {
        self.get_u32(idx)
    }

    #[wasm_bindgen(js_name = "getU64")]
    pub fn get_u64_js(&self, idx: usize) -> u64 {
        self.get_u64(idx)
    }

    #[wasm_bindgen(js_name = "getI32")]
    pub fn get_i32_js(&self, idx: usize) -> i32 {
        ffi_internal::get_col_nth_i32(&self.column, idx)
    }

    #[wasm_bindgen(js_name = "getI64")]
    pub fn get_i64_js(&self, idx: usize) -> i64 {
        ffi_internal::get_col_nth_i64(&self.column, idx)
    }

    #[wasm_bindgen(js_name = "size")]
    pub fn size(&self) -> usize {
        self.column.size()
    }
}

#[wasm_bindgen]
pub struct Schema {
    schema: UniquePtr<ffi_internal::Schema>,
}

impl Schema {
    pub fn columns(&self) -> Vec<String> {
        ffi_internal::get_schema_columns(&self.schema)
    }

    pub fn types(&self) -> Vec<DType> {
        ffi_internal::get_schema_types(&self.schema)
    }
}

#[wasm_bindgen]
pub struct Table {
    table: SharedPtr<ffi_internal::Table>,
}
// TODO: Figure out why this is necessary. No matter what I do,
//       it seems to choke on Sending C++ types since they wrap a void*
unsafe impl Send for Table {}
unsafe impl Sync for Table {}

#[wasm_bindgen]
impl Table {
    // TODO: Flesh this out more.
    pub fn from_csv(csv: String) -> Table {
        todo!()
    }
    pub fn from_arrow(bytes: Vec<u8>) -> Table {
        todo!()
    }
    pub fn from_json(json: String) -> Table {
        todo!()
    }
    // END TODO

    #[wasm_bindgen(constructor)]
    pub fn new() -> Self {
        let column_names = vec!["a".to_owned()];
        let data_types = vec![DType::DTYPE_INT64];
        let limit = 100;
        let index = "a".to_string();
        let table = ffi_internal::mk_table(column_names, data_types, limit, index);
        Table { table }
    }

    #[wasm_bindgen(js_name = "size")]
    pub fn size(&self) -> usize {
        self.table.size()
    }

    #[wasm_bindgen(js_name = "process")]
    pub fn process(&self) {
        ffi_internal::process_gnode(&self.table.get_gnode(), 0);
    }

    #[wasm_bindgen(js_name = "getColumnDtype")]
    pub fn get_col_dtype(&self, col: String) -> String {
        let col = self.get_column(&col);
        let dtype = col.get_dtype();
        format!("{:?}", dtype)
    }

    #[wasm_bindgen(js_name = "getColumn")]
    pub fn get_column(&self, name: &str) -> Column {
        let gnode = self.table.get_gnode();
        let data_table = gnode.get_table_sptr();
        let_cxx_string!(n = name);
        let col = data_table.get_column(&n);
        Column { column: col }
    }

    #[wasm_bindgen(js_name = "prettyPrint")]
    pub fn pretty_print(&self, num_rows: usize) -> String {
        ffi_internal::pretty_print(&self.table, num_rows)
    }

    #[wasm_bindgen(js_name = "makePort")]
    pub fn make_port(&self) -> usize {
        ffi_internal::make_table_port(&self.table)
    }
}

impl Table {
    pub fn schema(&self) -> Schema {
        let schema = ffi_internal::get_table_schema(&self.table);
        Schema { schema }
    }

    pub fn columns(&self) -> Vec<String> {
        self.schema().columns()
    }
}
