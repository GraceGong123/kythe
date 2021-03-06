#!/bin/bash
# Copyright 2015 The Kythe Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set -eo pipefail
BASE_DIR="$PWD/kythe/cxx/common/testdata"
TEST_JSON="${BASE_DIR}/net_client_test_data.json"
TEST_BIN="kythe/cxx/common/net_client_test"
OUT_DIR="$TEST_TMPDIR"

source "kythe/cxx/common/testdata/start_http_service.sh"

"$TEST_BIN" --xrefs="http://$LISTEN_AT"
