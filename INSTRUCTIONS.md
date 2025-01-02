# INSTRUCTIONS.md

This guide explains how to use the `elixir-hex-template` to create and set up a new Hex package project.

## Table of Contents

- [Cloning the Template](#cloning-the-template)
- [Customizing the Project](#customizing-the-project)
- [Setting Up Dependencies](#setting-up-dependencies)
- [Configuring GitHub Secrets](#configuring-github-secrets)
- [Setting Up Pre-commit Hooks](#setting-up-pre-commit-hooks)
- [Running Initial Checks](#running-initial-checks)
- [Using GitHub Actions](#using-github-actions)
- [Updating Metadata and Versioning](#updating-metadata-and-versioning)
- [Publishing to Hex.pm](#publishing-to-hexpm)
- [Maintaining Documentation and Security](#maintaining-documentation-and-security)

---

## Cloning the Template

1. Clone the template repository to your local machine:
   ```bash
   git clone https://github.com/<username>/elixir-hex-template.git my-new-project
   cd my-new-project
   ```

2. Remove the existing Git history:
   ```bash
   rm -rf .git
   ```

3. Initialize a new Git repository:
   ```bash
   git init
   git remote add origin https://github.com/<your-username>/<new-repo-name>.git
   ```

---

## Customizing the Project

1. **Update `mix.exs`**:
    - Replace `:app_name` with your application name.
    - Update the `version` to the starting version (e.g., `0.1.0`).
    - Update `description` with a short summary of your package's functionality.
    - Replace the `links` section with your GitHub repository URL.
    - Add or modify dependencies in the `deps` function as needed.

2. **Rename Files and Modules**:
    - Update the main module in the `lib/` directory to match your application name.
    - Update test files in the `test/` directory to reflect your application name.

3. **Update Documentation**:
    - Customize `README.md` with your project’s details.
    - Update the placeholders in `CONTRIBUTING.md`, `CHANGELOG.md`, and `SECURITY.md` to reflect your project.

4. **Version Tracking**:
    - Update the `VERSION` file to match your starting version (e.g., `0.1.0`).

---

## Setting Up Dependencies

Install dependencies for the project:

```bash
mix deps.get
```

---

## Configuring GitHub Secrets

To use GitHub Actions workflows (`elixir.yml` and `publish.yml`), set the following secrets in your GitHub repository:

1. **CODECOV_TOKEN**: Token for uploading test coverage reports to Codecov.
2. **HEX_API_KEY**: Your Hex.pm API key for publishing packages.

To add secrets:
1. Go to your GitHub repository.
2. Navigate to **Settings > Secrets and variables > Actions**.
3. Add the required secrets.

---

## Setting Up Pre-commit Hooks

Install and set up `pre-commit` to enforce code quality checks before committing:

1. Install `pre-commit`:
   ```bash
   pip install pre-commit
   ```

2. Install hooks:
   ```bash
   pre-commit install
   ```

3. Test the hooks:
   ```bash
   pre-commit run --all-files
   ```

The hooks will automatically run checks such as:
- Code formatting (`mix format`)
- Linting (`mix credo`)
- Running tests (`mix test`)
- Static analysis (`mix dialyzer`)

---

## Running Initial Checks

Before starting development, run the following checks to ensure the project is set up correctly:

1. Format code:
   ```bash
   mix format
   ```

2. Run the linter:
   ```bash
   mix credo --strict
   ```

3. Run tests:
   ```bash
   mix test
   ```

4. Perform static analysis:
   ```bash
   mix dialyzer
   ```

---

## Using GitHub Actions

### Continuous Integration (CI)

The `elixir.yml` workflow runs on pull requests to the `main` branch and performs the following:
- Installs dependencies
- Runs tests
- Performs static analysis with Dialyzer
- Runs the linter (`mix credo`)
- Uploads test coverage reports to Codecov

### Adjusting GitHub Actions Workflows

By default, GitHub Actions workflows in the template repository are triggered on push events. After cloning the template, you need to ensure the workflows are configured for your new project.

1. **Edit Workflow Files**

   Open the workflow files under `.github/workflows/` (e.g., `elixir.yml` and `publish.yml`) and update them to reflect your new repository. Specifically:
    - Update repository-specific references.
    - Ensure the workflows don’t unintentionally run in the template repository.

   For example, in `elixir.yml`, you can add a conditional check to prevent the workflow from running in the template repository:
   ```yaml
   jobs:
     build:
       if: github.repository != 'username/elixir-hex-template'
   ```

2. **Commit Your Changes**

   After making the changes, commit and push them to your new repository:
   ```bash
   git add .github/workflows/
   git commit -m "Configure GitHub Actions for new repository"
   git push origin main
   ```

This ensures the workflows only run in your new repository and not in the template repository.

### Publishing to Hex.pm

The `publish.yml` workflow is triggered on tags with the format `v*.*.*`. It:
1. Runs tests to ensure the project is working correctly.
2. Builds the package with `mix hex.build`.
3. Publishes the package to Hex.pm using the `HEX_API_KEY` secret.

---

## Updating Metadata and Versioning

1. **Update `CHANGELOG.md`**:
    - Document changes for every release in the `CHANGELOG.md` file following the [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format.

2. **Update `VERSION`**:
    - Increment the version in the `VERSION` file based on the type of release (patch, minor, major) as per [Semantic Versioning](https://semver.org/).

3. **Update `mix.exs` Version**:
    - Ensure the version in `mix.exs` matches the `VERSION` file.

---

## Publishing to Hex.pm

1. Bump the version in the `VERSION` file and `mix.exs` to match the new release.
2. Commit your changes:
   ```bash
   git add .
   git commit -m "Bump version to vX.Y.Z"
   ```
3. Create a new tag:
   ```bash
   git tag vX.Y.Z
   git push origin main --tags
   ```
4. The `publish.yml` workflow will automatically publish the new version to Hex.pm.

---

## Maintaining Documentation and Security

1. **Documentation**:
    - Keep the `README.md`, `CONTRIBUTING.md`, and `CHANGELOG.md` up to date with the latest project details.
    - Consider using tools like [ExDoc](https://hexdocs.pm/ex_doc/) to generate and publish API documentation to HexDocs.

2. **Security**:
    - Update the `SECURITY.md` file if your security policies change.
    - Promptly address vulnerabilities reported by users or dependencies.

---
