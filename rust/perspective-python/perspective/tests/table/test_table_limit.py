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

import random
import perspective as psp

client = psp.Server().new_local_client()
Table = client.table


class TestTableInfer(object):
    def test_table_limit_wraparound_does_not_respect_partial(self):
        t = Table({"a": "float", "b": "float"}, limit=3)
        t.update([{"a": 10}, {"b": 1}, {"a": 20}, {"a": 10, "b": 2}])
        d1 = t.view().to_columns()

        t2 = Table({"a": "float", "b": "float"}, limit=3)
        t2.update([{"a": 10}, {"b": 1}, {"a": 20}, {"b": 2}])
        d2 = t2.view().to_columns()

        assert d1 == d2

    def test_table_limit_with_json(self):
        t = Table({"a": [1, 2, 3]}, limit=1)
        assert t.size() == 1

    def test_table_limit_wrap_around_always_overwrites_oldest_insert(self):
        t = Table({"x": "integer"}, limit=10)

        data = []
        for i in range(15):
            row = {"x": i}
            data.append(row)
            t.update([row])
            t.size()

        v = t.view()
        assert data[-10:] == v.to_json()

    def test_table_limit_wrap_around_respectts_num_table_rows(self):
        t = Table({"x": "integer", "group": "string"}, limit=10)

        v = t.view(split_by=["group"])

        data = []
        for i in range(5):
            group = random.choice(["a", "b"])
            row = {"x": i, "group": group}
            data.append(row)
            t.update([row] * 6)
            t.size()

        assert v.dimensions()["num_table_rows"] == 10
        assert v.dimensions()["num_view_rows"] == 10
