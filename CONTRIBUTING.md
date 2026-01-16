# Contributing to Mino Settlement Contracts

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Getting Started

1. **Fork the repository** and clone your fork
2. **Install dependencies**: `forge install`
3. **Build**: `forge build`
4. **Run tests**: `forge test`

## Development Workflow

### Code Style

- Follow the existing code style and Solidity conventions
- Use `forge fmt` to format code before committing
- Add NatSpec documentation for all public/external functions
- Use descriptive variable and function names

### Testing

- All new features must include tests
- Run the full test suite before submitting: `forge test`
- Aim for comprehensive coverage of edge cases
- Use fuzz testing where appropriate

### Commit Messages

Use conventional commit format:

```
type(scope): description

[optional body]
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`

Examples:
- `feat(settlement): add pausable circuit breaker`
- `fix(simulator): handle stale block numbers`
- `docs: update deployment guide`

## Submitting Changes

1. Create a feature branch: `git checkout -b feat/my-feature`
2. Make your changes with clear, atomic commits
3. Ensure all tests pass: `forge test`
4. Format code: `forge fmt`
5. Push and open a Pull Request

### Pull Request Guidelines

- Provide a clear description of the changes
- Reference any related issues
- Ensure CI checks pass
- Be responsive to review feedback

## Security

If you discover a security vulnerability, please **do not** open a public issue. Instead, contact the maintainers privately.

## Questions?

Open an issue for questions or discussions about the codebase.
