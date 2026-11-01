library(hello)

result <- hello("you")
stopifnot(
  identical(result$json, "{\"hello\":\"you\"}"),
  grepl("<p>Hello, you</p>", result$html, fixed = TRUE),
  identical(result$glue, "Hello, you"),
  nzchar(result$praise),
  identical(result$size, "1.34 kB"),
  identical(result$match, "hello"),
  isTRUE(result$generic)
)
