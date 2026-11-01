# Greets with glue, and prints the version of glue in the project library.
cat(glue::glue("glue {packageVersion('glue')}"), "\n")
