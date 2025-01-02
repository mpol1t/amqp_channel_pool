# Contributing to <Project Name>

Thank you for your interest in contributing to `<Project Name>`! We welcome contributions of all kinds, including bug fixes, new features, and improvements to documentation.

## Getting Started

1. **Fork the Repository**  
   Fork the repository to your GitHub account.

2. **Clone the Repository**  
   Clone your fork locally:
   ```bash
   git clone https://github.com/<your-username>/<repository-name>.git
   cd <repository-name>
   ```

3. **Set Up the Environment**  
   Install dependencies:
   ```bash
   mix deps.get
   ```

4. **Run the Tests**  
   Ensure everything is working before making changes:
   ```bash
   mix test
   ```

## How to Contribute

### Reporting Issues

If you encounter a bug or have a feature request, please open an issue on GitHub. Provide as much detail as possible to help us understand and reproduce the problem.

### Making Changes

1. Create a new branch:
   ```bash
   git checkout -b feature/<feature-name>
   ```

2. Make your changes and add tests where applicable.

3. Run the tests and check formatting:
   ```bash
   mix test
   mix format
   mix credo
   ```

4. Commit your changes:
   ```bash
   git commit -m "Add <feature-name>: Brief description of the changes"
   ```

5. Push the branch to your fork:
   ```bash
   git push origin feature/<feature-name>
   ```

6. Open a Pull Request (PR) on the original repository. Provide a clear description of the changes and reference related issues, if any.

## Code Style

We use Elixir’s built-in formatter (`mix format`) and Credo for linting. Please run them before committing your changes:
```bash
mix format
mix credo --strict
```

## License

By contributing, you agree that your contributions will be licensed under the Apache License, Version 2.0.