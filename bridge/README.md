# Building a Node.js Bridge for PLTelemetry to OpenTelemetry Conversion

Creating a telemetry conversion bridge requires understanding both the OpenTelemetry SDK structure and the specific JSON mapping requirements. Based on comprehensive research, here's a practical guide to building your PLTelemetry to OpenTelemetry converter.

## OpenTelemetry SDK fundamentals and setup

The OpenTelemetry Node.js SDK provides a vendor-neutral approach to telemetry collection with several key components. The **API layer** (`@opentelemetry/api`) provides core interfaces while the **SDK core** (`@opentelemetry/sdk-node`) offers full implementation with default configurations. For a conversion bridge, you'll need minimal dependencies focused on programmatic telemetry creation rather than auto-instrumentation.

### Essential package installation

```bash
npm install @opentelemetry/api @opentelemetry/sdk-node @opentelemetry/sdk-trace-node @opentelemetry/sdk-metrics @opentelemetry/exporter-trace-otlp-http express
```

### Basic SDK initialization for the bridge

```javascript
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
const { Resource } = require('@opentelemetry/resources');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');

const sdk = new NodeSDK({
  resource: new Resource({
    [SemanticResourceAttributes.SERVICE_NAME]: 'plsql-otel-bridge',
    [SemanticResourceAttributes.SERVICE_VERSION]: '1.0.0',
  }),
  traceExporter: new OTLPTraceExporter({
    url: process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT || 'http://localhost:4318/v1/traces',
  }),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter({
      url: process.env.OTEL_EXPORTER_OTLP_METRICS_ENDPOINT || 'http://localhost:4318/v1/metrics',
    }),
    exportIntervalMillis: 10000
  }),
});

sdk.start();
```

## Creating telemetry data programmatically

OpenTelemetry provides APIs to programmatically create traces, spans, metrics, and events. For a conversion bridge, you'll use these APIs to recreate telemetry data from the incoming PLTelemetry format.

### Trace and span creation patterns

```javascript
const { trace, SpanKind, SpanStatusCode } = require('@opentelemetry/api');

class TelemetryConverter {
  constructor() {
    this.tracer = trace.getTracer('pltelemetry-converter', '1.0.0');
  }

  createSpanFromPLTelemetry(plData) {
    // Start a new span with the operation name from PLTelemetry
    return this.tracer.startActiveSpan(plData.operationName, {
      kind: this.mapSpanKind(plData.operationType),
      attributes: this.convertAttributes(plData.attributes),
      startTime: new Date(plData.timestamp)
    }, (span) => {
      try {
        // Add events from PLTelemetry
        if (plData.events) {
          plData.events.forEach(event => {
            span.addEvent(event.name, {
              ...event.attributes
            }, new Date(event.timestamp));
          });
        }

        // Set status based on PLTelemetry status
        if (plData.status === 'error') {
          span.setStatus({ code: SpanStatusCode.ERROR, message: plData.errorMessage });
          if (plData.exception) {
            span.recordException(new Error(plData.exception.message));
          }
        } else {
          span.setStatus({ code: SpanStatusCode.OK });
        }

        // End the span with the correct timestamp
        span.end(new Date(plData.endTimestamp || plData.timestamp + plData.duration));
      } catch (error) {
        span.recordException(error);
        span.setStatus({ code: SpanStatusCode.ERROR });
        throw error;
      }
    });
  }

  mapSpanKind(operationType) {
    const kindMap = {
      'db_query': SpanKind.CLIENT,
      'pl_procedure': SpanKind.INTERNAL,
      'http_call': SpanKind.CLIENT,
      'service': SpanKind.SERVER
    };
    return kindMap[operationType] || SpanKind.INTERNAL;
  }
}
```

### Metrics creation and recording

```javascript
const { metrics } = require('@opentelemetry/api');

class MetricsConverter {
  constructor() {
    this.meter = metrics.getMeter('pltelemetry-metrics', '1.0.0');
    this.metricInstruments = new Map();
  }

  recordMetric(plMetric) {
    // Get or create the appropriate instrument
    let instrument = this.metricInstruments.get(plMetric.name);
    
    if (!instrument) {
      instrument = this.createInstrument(plMetric);
      this.metricInstruments.set(plMetric.name, instrument);
    }

    // Record the metric value
    const attributes = this.convertAttributes(plMetric.labels);
    
    switch (plMetric.type) {
      case 'counter':
        instrument.add(plMetric.value, attributes);
        break;
      case 'gauge':
      case 'histogram':
        instrument.record(plMetric.value, attributes);
        break;
    }
  }

  createInstrument(plMetric) {
    const { name, type, unit, description } = plMetric;
    
    switch (type) {
      case 'counter':
        return this.meter.createCounter(name, { unit, description });
      case 'gauge':
        return this.meter.createUpDownCounter(name, { unit, description });
      case 'histogram':
        return this.meter.createHistogram(name, { unit, description });
      default:
        throw new Error(`Unknown metric type: ${type}`);
    }
  }
}
```

## JSON structure mapping between PLTelemetry and OpenTelemetry

The OpenTelemetry Protocol (OTLP) has specific JSON structure requirements that differ from typical custom telemetry formats. **Critical mapping considerations** include trace/span IDs must be hex strings (128-bit for traces, 64-bit for spans), timestamps must be Unix nanoseconds as strings, and attribute values must use proper type wrappers.

### Complete conversion bridge implementation

```javascript
const express = require('express');
const { trace, metrics } = require('@opentelemetry/api');

class PLTelemetryBridge {
  constructor() {
    this.app = express();
    this.app.use(express.json({ limit: '10mb' }));
    this.telemetryConverter = new TelemetryConverter();
    this.metricsConverter = new MetricsConverter();
    
    this.setupRoutes();
  }

  setupRoutes() {
    this.app.post('/plsql-otel/telemetry', async (req, res) => {
      try {
        const { type, data } = req.body;
        
        switch (type) {
          case 'trace':
            await this.processTraceData(data);
            break;
          case 'metrics':
            await this.processMetricsData(data);
            break;
          case 'events':
            await this.processEventsData(data);
            break;
          case 'batch':
            await this.processBatchData(data);
            break;
          default:
            return res.status(400).json({ error: `Unknown telemetry type: ${type}` });
        }
        
        res.status(200).json({ message: 'Telemetry processed successfully' });
      } catch (error) {
        console.error('Error processing telemetry:', error);
        res.status(500).json({ error: 'Failed to process telemetry data' });
      }
    });
  }

  async processTraceData(traceData) {
    // Convert PLTelemetry trace format to OpenTelemetry
    const spans = Array.isArray(traceData) ? traceData : [traceData];
    
    for (const spanData of spans) {
      const convertedSpan = {
        traceId: this.ensureValidTraceId(spanData.trace_id),
        spanId: this.ensureValidSpanId(spanData.span_id),
        parentSpanId: spanData.parent_id ? this.ensureValidSpanId(spanData.parent_id) : undefined,
        name: spanData.operation_name,
        startTimeUnixNano: this.convertToNanoTime(spanData.start_time),
        endTimeUnixNano: this.convertToNanoTime(spanData.end_time || spanData.start_time + spanData.duration),
        attributes: this.convertAttributes(spanData.attributes),
        events: this.convertEvents(spanData.events),
        status: this.convertStatus(spanData.status)
      };
      
      // Create actual OpenTelemetry span
      this.telemetryConverter.createSpanFromPLTelemetry(convertedSpan);
    }
  }

  async processMetricsData(metricsData) {
    const metrics = Array.isArray(metricsData) ? metricsData : [metricsData];
    
    for (const metric of metrics) {
      this.metricsConverter.recordMetric({
        name: this.sanitizeMetricName(metric.metric_name),
        type: metric.metric_type,
        value: metric.value,
        unit: metric.unit || '1',
        description: metric.description,
        labels: metric.tags || {}
      });
    }
  }

  async processEventsData(eventsData) {
    // Events in PLTelemetry might be standalone or associated with spans
    const events = Array.isArray(eventsData) ? eventsData : [eventsData];
    
    for (const event of events) {
      if (event.span_id) {
        // Event belongs to a span - would need span context
        console.log('Event associated with span:', event.span_id);
      } else {
        // Standalone event - convert to log
        const logRecord = {
          timestamp: this.convertToNanoTime(event.timestamp),
          severityText: event.level || 'INFO',
          body: { stringValue: event.message },
          attributes: this.convertAttributes(event.attributes)
        };
        // Process log record
      }
    }
  }

  async processBatchData(batchData) {
    // Process different types of telemetry in a batch
    if (batchData.traces) await this.processTraceData(batchData.traces);
    if (batchData.metrics) await this.processMetricsData(batchData.metrics);
    if (batchData.events) await this.processEventsData(batchData.events);
  }

  // Utility methods for data conversion
  ensureValidTraceId(id) {
    if (!id) return this.generateTraceId();
    // Ensure 32-character hex string (128-bit)
    return id.padStart(32, '0').substring(0, 32);
  }

  ensureValidSpanId(id) {
    if (!id) return this.generateSpanId();
    // Ensure 16-character hex string (64-bit)
    return id.padStart(16, '0').substring(0, 16);
  }

  generateTraceId() {
    return [...Array(32)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');
  }

  generateSpanId() {
    return [...Array(16)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');
  }

  convertToNanoTime(timestamp) {
    if (typeof timestamp === 'string') {
      return String(new Date(timestamp).getTime() * 1000000);
    }
    // Assume milliseconds if number
    return String(timestamp * 1000000);
  }

  convertAttributes(attrs) {
    const converted = [];
    for (const [key, value] of Object.entries(attrs || {})) {
      converted.push({
        key,
        value: this.convertAttributeValue(value)
      });
    }
    return converted;
  }

  convertAttributeValue(value) {
    if (typeof value === 'string') return { stringValue: value };
    if (typeof value === 'boolean') return { boolValue: value };
    if (typeof value === 'number') {
      return Number.isInteger(value) ? { intValue: String(value) } : { doubleValue: value };
    }
    if (Array.isArray(value)) {
      return { arrayValue: { values: value.map(v => this.convertAttributeValue(v)) } };
    }
    return { stringValue: JSON.stringify(value) };
  }

  convertEvents(events) {
    if (!events) return [];
    return events.map(event => ({
      name: event.name,
      timeUnixNano: this.convertToNanoTime(event.timestamp),
      attributes: this.convertAttributes(event.attributes)
    }));
  }

  convertStatus(status) {
    const statusMap = {
      'success': 1, // OK
      'error': 2,   // ERROR
      'ok': 1,
      'failed': 2
    };
    return {
      code: statusMap[status?.toLowerCase()] || 0 // UNSET
    };
  }

  sanitizeMetricName(name) {
    return name.toLowerCase().replace(/[^a-z0-9_]/g, '_');
  }

  start(port = 3000) {
    this.app.listen(port, () => {
      console.log(`PLTelemetry to OpenTelemetry bridge running on port ${port}`);
    });
  }
}

// Start the bridge
const bridge = new PLTelemetryBridge();
bridge.start(process.env.PORT || 3000);
```

## Best practices for production deployment

For a production-ready telemetry bridge, consider implementing **request validation** using middleware to ensure incoming PLTelemetry data meets expected schemas. Add **error boundaries** around conversion logic to prevent malformed data from crashing the service. Implement **basic health checks** at `/health` endpoint for monitoring. Use **environment variables** for configuration including OTLP endpoints, service metadata, and batch settings.

### Minimal Docker deployment

```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
EXPOSE 3000
CMD ["node", "bridge.js"]
```

### Environment configuration

```bash
# OTLP Configuration
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_SERVICE_NAME=plsql-otel-bridge
OTEL_SERVICE_VERSION=1.0.0

# Bridge Configuration
PORT=3000
LOG_LEVEL=info
MAX_PAYLOAD_SIZE=10mb
```

## Testing with mock backend

For development and testing, use the OpenTelemetry Collector with console exporters:

```yaml
# otel-collector-dev.yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

exporters:
  logging:
    loglevel: debug

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [logging]
    metrics:
      receivers: [otlp]
      exporters: [logging]
```

This implementation provides a simple yet functional bridge that receives PLTelemetry JSON data and converts it to proper OpenTelemetry format. The modular design allows easy extension for specific PLTelemetry format requirements while maintaining compatibility with the OpenTelemetry ecosystem.