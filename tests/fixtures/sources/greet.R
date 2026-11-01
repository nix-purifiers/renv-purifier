# Prints a greeting from the package outside the project and a word of
# praise from the package locked as a zip file.
cat(greeter::greet("you"), "\n", sep = "")
cat(nzchar(praise::praise()), "\n", sep = "")
