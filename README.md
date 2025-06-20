# PLTelemetry

> Lightweight OpenTelemetry-style tracing toolkit for Oracle PL/SQL systems.

PLTelemetry is a minimal yet powerful tracing library for Oracle databases. Inspired by OpenTelemetry principles, it brings structured observability to legacy PL/SQL applications—without external agents or dependencies.

## 🚀 Features

- Simple tracing API: `start_trace`, `start_span`, `end_span`, `add_event`, `log_metric`
- Context propagation via session variables (`trace_id`, `span_id`)
- Optional attributes and custom events
- JSON-based structured payloads
- Backend integration via HTTP (`send_to_backend`)
- Async mode support
- Zero external dependencies (pure PL/SQL)

## 📦 Installation

1. Execute the files in `plsql/` to install the package in your Oracle database:
   ```sql
   @plsql/PLTelemetry_PKH.sql
   @plsql/PLTelemetry_PKB.sql

## Configure the end point and API key

BEGIN
  pltelemetry.set_backend_url('https://your-tracing-server.com/api/logs');
  pltelemetry.set_api_key('YOUR_SECRET_KEY');
  pltelemetry.set_async_mode(TRUE);
END;

## Example

BEGIN
  pltelemetry.start_trace('my_trace');

  pltelemetry.start_span('user_login');
  pltelemetry.add_event('checking credentials');
  pltelemetry.add_attribute('username', 'john_doe');
  pltelemetry.end_span;

  pltelemetry.send_to_backend;
END;

## Backend Format

{
  "trace_id": "e401ea4c-cc30-4438-9f55-7338852fe900",
  "spans": [
    {
      "span_id": "7c4f6b5f-117a-43f0-8bfc-bf2c171ea9dc",
      "name": "user_login",
      "attributes": {
        "username": "john_doe"
      },
      "events": ["checking credentials"]
    }
  ]
}
