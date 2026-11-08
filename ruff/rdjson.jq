# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# ruff's RDJSON output (`--output-format=rdjson`, pretty printed) to the one RDJSON document
# reviewdog reads. Run by run-passes.sh as `jq -R -s -L lib --arg workspace <root> -f
# ruff/rdjson.jq` on the hook's output.
#
# pre-commit may run the hook more than once on parts of the file list, so the output can hold
# several documents: their diagnostics are concatenated, under the first one's source and
# severity. Suggestions are removed, as in v1: ruff's suggested edits are made against the file
# before `--fix` changed it, and the tree report already posts the fixes. A line outside a JSON
# document, or a document that is not RDJSON, is an error.

include "rdjson";

json_documents
| if (.other | length) > 0 then error("ruff printed a line outside its RDJSON output: \(.other[0][0:200])")
  elif (.documents | length) == 0 then error("ruff printed no RDJSON document")
  else
    .documents
    | map(rdjson_normalize($workspace))
    | .[0] + {diagnostics: [.[].diagnostics[] | del(.suggestions)]}
  end
