markdown# Contributing to PLTelemetry

## Development Setup
1. Oracle Database 12c+ with development schema
2. Required grants for UTL_HTTP and DBMS_CRYPTO
3. Test data setup

## Code Style
- Use 4 spaces for indentation
- Comment all public procedures/functions
- Follow Oracle naming conventions
- Include error handling in all procedures

## Testing
- Test against Oracle 12c, 18c, 19c, 21c
- Include both sync and async mode tests
- Test error scenarios

## Pull Request Process
1. Fork the repository
2. Create feature branch: `git checkout -b feature/amazing-feature`
3. Commit changes: `git commit -m 'Add amazing feature'`
4. Push to branch: `git push origin feature/amazing-feature`