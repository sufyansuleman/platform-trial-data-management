# Entry point for R CMD check style runs. Day to day, prefer:
#   Rscript -e 'testthat::test_dir("tests/testthat")'
library(testthat)
test_dir("tests/testthat")
