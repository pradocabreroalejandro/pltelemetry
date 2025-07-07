// =============================================================================
// PLTelemetry Example 04 - Financial Reports API Server
// Node.js service with native OpenTelemetry → Oracle via ORDS
// =============================================================================

const express = require('express');
const axios = require('axios');
const { trace, SpanStatusCode, SpanKind } = require('@opentelemetry/api');
const { v4: uuidv4 } = require('uuid');

const app = express();
const port = process.env.PORT || 3001;
const oracleOrdsUrl = process.env.ORACLE_ORDS_URL || 'http://localhost:8080';

// Get the tracer for this service
const tracer = trace.getTracer('financial-reports-api', '1.0.0');

// Middleware
app.use(express.json());

// Add correlation ID to all requests
app.use((req, res, next) => {
  req.correlationId = req.headers['x-correlation-id'] || uuidv4();
  res.setHeader('x-correlation-id', req.correlationId);
  next();
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy', 
    service: 'financial-reports-api',
    timestamp: new Date().toISOString(),
    version: '1.0.0'
  });
});

// =============================================================================
// MAIN FINANCIAL REPORTS ENDPOINT
// =============================================================================
app.post('/api/reports/financial-summary', async (req, res) => {
  // Get the current span (created automatically by OTEL instrumentation)
  const currentSpan = trace.getActiveSpan();
  
  try {
    const { customer_id, period, include_forecasts = true } = req.body;
    
    // Add business context to the automatically created span
    currentSpan?.setAttributes({
      'business.operation': 'financial_summary_generation',
      'customer.id': customer_id,
      'report.period': period,
      'report.include_forecasts': include_forecasts,
      'correlation.id': req.correlationId
    });

    // Validate input parameters
    await validateRequest(customer_id, period);

    // Step 1: Fetch base data from Oracle via ORDS
    const oracleData = await fetchOracleFinancialData(customer_id, period, req.correlationId);

    // Step 2: Generate forecasts (if requested)
    let forecastData = null;
    if (include_forecasts) {
      forecastData = await generateForecasts(customer_id, period, oracleData);
    }

    // Step 3: Format final report
    const finalReport = await formatFinancialReport(oracleData, forecastData, period);

    // Success metrics
    currentSpan?.setAttributes({
      'report.data_points': oracleData.transactions?.length || 0,
      'report.forecast_generated': !!forecastData,
      'report.total_size_kb': Math.round(JSON.stringify(finalReport).length / 1024)
    });

    currentSpan?.setStatus({ code: SpanStatusCode.OK });

    res.json({
      success: true,
      correlation_id: req.correlationId,
      report: finalReport,
      metadata: {
        generated_at: new Date().toISOString(),
        processing_time_ms: Date.now() - req.startTime,
        data_source: 'oracle-ords',
        forecast_included: !!forecastData
      }
    });

  } catch (error) {
    console.error('❌ Financial report generation failed:', error);
    
    currentSpan?.setAttributes({
      'error.type': error.constructor.name,
      'error.message': error.message,
      'error.correlation_id': req.correlationId
    });
    
    currentSpan?.setStatus({ 
      code: SpanStatusCode.ERROR, 
      message: error.message 
    });

    res.status(500).json({
      success: false,
      correlation_id: req.correlationId,
      error: {
        message: 'Failed to generate financial report',
        details: error.message,
        timestamp: new Date().toISOString()
      }
    });
  }
});

// =============================================================================
// BUSINESS LOGIC FUNCTIONS (with manual tracing)
// =============================================================================

/**
 * Validate request parameters
 */
async function validateRequest(customer_id, period) {
  return tracer.startActiveSpan('validate_request_parameters', async (span) => {
    try {
      span.setAttributes({
        'validation.customer_id': customer_id,
        'validation.period': period,
        'span.kind': 'internal'
      });

      // Simulate validation logic with artificial delay
      await new Promise(resolve => setTimeout(resolve, 200));

      if (!customer_id || !period) {
        throw new Error('Missing required parameters: customer_id and period');
      }

      if (!/^\d{4}-Q[1-4]$/.test(period)) {
        throw new Error('Invalid period format. Expected: YYYY-Q[1-4]');
      }

      span.addEvent('validation_completed', {
        'validation.result': 'success',
        'validation.duration_ms': 200
      });

      span.setStatus({ code: SpanStatusCode.OK });

    } catch (error) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
      throw error;
    } finally {
      span.end();
    }
  });
}

/**
 * Fetch financial data from Oracle via ORDS
 */
async function fetchOracleFinancialData(customer_id, period, correlationId) {
  return tracer.startActiveSpan('fetch_oracle_financial_data', { kind: SpanKind.CLIENT }, async (span) => {
    try {
      span.setAttributes({
        'http.method': 'POST',
        'http.url': `${oracleOrdsUrl}/ords/pltdb/financial/reports/summary`,
        'oracle.customer_id': customer_id,
        'oracle.period': period,
        'oracle.service': 'ords',
        'correlation.id': correlationId
      });

      // Get current trace context to pass to Oracle
      const traceContext = getTraceContext();
      
      span.addEvent('calling_oracle_ords', {
        'trace.propagation': 'w3c_headers',
        'oracle.endpoint': '/financial/reports/summary'
      });

      // Call Oracle ORDS with trace context in headers
      const response = await axios.post(
        `${oracleOrdsUrl}/ords/pltdb/financial/reports/summary`,
        {
          customer_id: customer_id,
          period: period,
          include_metrics: true
        },
        {
          headers: {
            'Content-Type': 'application/json',
            'X-Correlation-ID': correlationId,
            // W3C Trace Context headers for distributed tracing
            'traceparent': traceContext.traceparent,
            'tracestate': traceContext.tracestate || '',
            'X-PLT-Trace-ID': traceContext.traceId,
            'X-PLT-Span-ID': traceContext.spanId
          },
          timeout: 30000
        }
      );

      span.setAttributes({
        'http.response.status_code': response.status,
        'http.response.content_length': JSON.stringify(response.data).length,
        'oracle.response.success': true,
        'oracle.data.transactions_count': response.data.transactions?.length || 0
      });

      span.addEvent('oracle_response_received', {
        'response.size_bytes': JSON.stringify(response.data).length,
        'response.transactions': response.data.transactions?.length || 0
      });

      span.setStatus({ code: SpanStatusCode.OK });
      return response.data;

    } catch (error) {
      span.setAttributes({
        'error.type': error.constructor.name,
        'error.message': error.message,
        'oracle.response.success': false
      });

      if (error.response) {
        span.setAttributes({
          'http.response.status_code': error.response.status,
          'oracle.error.details': error.response.data?.message || 'Unknown Oracle error'
        });
      }

      span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
      throw new Error(`Oracle ORDS call failed: ${error.message}`);
    } finally {
      span.end();
    }
  });
}

/**
 * Generate ML forecasts based on historical data
 */
async function generateForecasts(customer_id, period, historicalData) {
  return tracer.startActiveSpan('generate_ml_forecasts', async (span) => {
    try {
      span.setAttributes({
        'ml.model': 'simple_linear_regression',
        'ml.customer_id': customer_id,
        'ml.period': period,
        'ml.input_data_points': historicalData.transactions?.length || 0
      });

      span.addEvent('forecast_calculation_started', {
        'ml.algorithm': 'linear_regression',
        'historical.data_points': historicalData.transactions?.length || 0
      });

      // Simulate ML processing with artificial delay
      await new Promise(resolve => setTimeout(resolve, 400));

      // Generate fake forecast data
      const forecastData = {
        next_quarter_revenue: 125000 + (Math.random() * 25000),
        growth_rate: 0.05 + (Math.random() * 0.10),
        confidence_level: 0.85 + (Math.random() * 0.10),
        risk_factors: ['market_volatility', 'seasonal_trends'],
        generated_at: new Date().toISOString()
      };

      span.setAttributes({
        'forecast.revenue': forecastData.next_quarter_revenue,
        'forecast.growth_rate': forecastData.growth_rate,
        'forecast.confidence': forecastData.confidence_level
      });

      span.addEvent('forecast_completed', {
        'forecast.duration_ms': 400,
        'forecast.confidence': forecastData.confidence_level
      });

      span.setStatus({ code: SpanStatusCode.OK });
      return forecastData;

    } catch (error) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
      throw error;
    } finally {
      span.end();
    }
  });
}

/**
 * Format the final financial report
 */
async function formatFinancialReport(oracleData, forecastData, period) {
  return tracer.startActiveSpan('format_financial_report', async (span) => {
    try {
      span.setAttributes({
        'report.period': period,
        'report.has_forecasts': !!forecastData,
        'report.oracle_data_size': JSON.stringify(oracleData).length
      });

      // Simulate report formatting with artificial delay
      await new Promise(resolve => setTimeout(resolve, 100));

      const finalReport = {
        period: period,
        summary: {
          total_revenue: oracleData.total_revenue || 0,
          total_transactions: oracleData.transactions?.length || 0,
          average_transaction: oracleData.average_transaction || 0,
          top_categories: oracleData.top_categories || []
        },
        oracle_data: oracleData,
        forecasts: forecastData,
        generated_by: 'financial-reports-api',
        processing_chain: ['nodejs_validation', 'oracle_data_fetch', 'ml_forecasting', 'report_formatting']
      };

      span.setAttributes({
        'report.final_size_bytes': JSON.stringify(finalReport).length,
        'report.sections': Object.keys(finalReport).length
      });

      span.addEvent('report_formatting_completed');
      span.setStatus({ code: SpanStatusCode.OK });
      
      return finalReport;

    } catch (error) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
      throw error;
    } finally {
      span.end();
    }
  });
}

/**
 * Get current trace context for propagation to Oracle
 */
function getTraceContext() {
  const activeSpan = trace.getActiveSpan();
  if (!activeSpan) {
    return { traceparent: '00-00000000000000000000000000000000-0000000000000000-00' };
  }

  const spanContext = activeSpan.spanContext();
  const traceId = spanContext.traceId;
  const spanId = spanContext.spanId;
  const traceFlags = spanContext.traceFlags;

  // Format as W3C traceparent header
  const traceparent = `00-${traceId}-${spanId}-0${traceFlags}`;

  return {
    traceparent,
    traceId,
    spanId,
    traceFlags
  };
}

// Add request timing middleware
app.use((req, res, next) => {
  req.startTime = Date.now();
  next();
});

// Start the server
app.listen(port, () => {
  console.log('🚀 Financial Reports API started');
  console.log(`📊 Server running on port ${port}`);
  console.log(`🔗 Oracle ORDS URL: ${oracleOrdsUrl}`);
  console.log(`🎯 Ready for distributed tracing!`);
  console.log('');
  console.log('📋 Available endpoints:');
  console.log(`   GET  http://localhost:${port}/health`);
  console.log(`   POST http://localhost:${port}/api/reports/financial-summary`);
  console.log('');
});