# Function to print a personalized greeting
print_greeting <- function(name) {
  if (!is.null(name)) {
    greeting <- paste("Hello,", name, "!")
  } else {
    greeting <- "Hello, World!"
  }
  print(greeting)
}

# Call the function with a user name
print_greeting("David")
