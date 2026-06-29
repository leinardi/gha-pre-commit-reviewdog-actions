{
  source: {
    name: "sqlfluff",
    url: "https://github.com/sqlfluff/sqlfluff"
  },
  diagnostics: (
    map(
      . as $file
      | $file.violations[] as $v
      | {
          message: $v.description,
          code: {
            value: $v.code,
            url: "https://docs.sqlfluff.com/en/stable/rules.html#sqlfluff.core.rules.Rule_\($v.code)"
          },
          location: {
            path: $file.filepath,
            range: {
              start: {
                line: $v.start_line_no,
                column: $v.start_line_pos
              },
              end: {
                line: $v.end_line_no,
                column: $v.end_line_pos
              }
            }
          },
          severity: (if $v.warning then "WARNING" else "ERROR" end)
        }
    )
  )
}
