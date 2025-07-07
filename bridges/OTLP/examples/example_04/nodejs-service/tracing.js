// =============================================================================
// PLTelemetry Example 04 - OpenTelemetry Tracing Setup
// Native OTEL instrumentation for Node.js
// =============================================================================

const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { HttpInstrumentation } = require('@opentelemetry/instrumentation-http');
const { ExpressInstrumentation } = require('@opentelemetry/instrumentation-express');
const { SemanticResourceAttributes } = require('@opentelemetry/semantic-conventions');

// Configure OTLP exporter to send to Tempo
const traceExporter = new OTLPTraceExporter({
  url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4318/v1/traces',
  headers: {
    'Content-Type': 'application/json',
  },
});

// Initialize the SDK with auto-instrumentation
const sdk = new NodeSDK({
  serviceName: process.env.OTEL_SERVICE_NAME || 'financial-reports-api',
  serviceVersion: process.env.OTEL_SERVICE_VERSION || '1.0.0',
  
  // Resource attributes for service identification
  resourceAttributes: {
    [SemanticResourceAttributes.SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || 'financial-reports-api',
    [SemanticResourceAttributes.SERVICE_VERSION]: process.env.OTEL_SERVICE_VERSION || '1.0.0',
    [SemanticResourceAttributes.SERVICE_NAMESPACE]: 'plt-examples',
    [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: process.env.NODE_ENV || 'development',
    'example.type': 'distributed-tracing',
    'plt.bridge.target': 'oracle-plsql'
  },
  
  // Configure trace exporter
  traceExporter,
  
  // Auto-instrumentation for HTTP and Express
  instrumentations: [
    new HttpInstrumentation({
      // Add custom attributes to HTTP spans
      requestHook: (span, request) => {
        span.setAttributes({
          'http.request.method': request.method,
          'http.url': request.url,
          'user_agent': request.headers['user-agent'] || 'unknown'
        });
      },
      responseHook: (span, response) => {
        span.setAttributes({
          'http.response.status_code': response.statusCode,
          'http.response.content_length': response.headers['content-length'] || 0
        });
      }
    }),
    
    new ExpressInstrumentation({
      // Add Express-specific attributes
      requestHook: (span, request) => {
        span.setAttributes({
          'express.route': request.route?.path || 'unknown',
          'express.method': request.method
        });
      }
    })
  ],
});

// Initialize the SDK
try {
  sdk.start();
  console.log('🚀 OpenTelemetry SDK initialized successfully');
  console.log(`📊 Traces will be sent to: ${process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:4318/v1/traces'}`);
  console.log(`🏷️  Service: ${process.env.OTEL_SERVICE_NAME || 'financial-reports-api'} v${process.env.OTEL_SERVICE_VERSION || '1.0.0'}`);
} catch (error) {
  console.error('❌ Failed to initialize OpenTelemetry SDK:', error);
  process.exit(1);
}

// Graceful shutdown
process.on('SIGTERM', () => {
  sdk.shutdown()
    .then(() => console.log('🛑 OpenTelemetry SDK terminated'))
    .catch((error) => console.error('❌ Error terminating OpenTelemetry SDK', error))
    .finally(() => process.exit(0));
});

module.exports = sdk;