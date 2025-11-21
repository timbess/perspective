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
    ]
}

rows = [reduce(lambda acc, col_name: {**acc, col_name: table[col_name][i]}, table.keys(), {}) for i in range(len(table["division"]))]


with open("test.json", 'w') as f:
    json.dump(rows, f)

_ =db.read_json("test.json")

def main():
    _ = db.sql(
        f"""
        SET default_null_order=NULLS_FIRST_ON_ASC_LAST_ON_DESC;
        CREATE TABLE data_source_one AS
            SELECT * FROM 'test.json';
        """,
    )

    virtual_server = perspective.virtual_servers.duckdb.DuckDBVirtualServer(db)
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
