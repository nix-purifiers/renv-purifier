#' Greets `name`, using one function from each locked dependency.
hello <- function(name) {
  greeting <- hellohelper::greeting(name)
  document <- xml2::read_xml(sprintf("<p>%s</p>", greeting))
  list(
    json = as.character(jsonlite::toJSON(list(hello = name), auto_unbox = TRUE)),
    html = as.character(document),
    glue = as.character(glue::glue("Hello, {name}")),
    praise = praise::praise("${Adjective}"),
    size = prettyunits::pretty_bytes(1337),
    match = unname(rematch::re_match("(?<word>[a-z]+)", "hello")[, "word"]),
    generic = is.function(BiocGenerics::combine)
  )
}
