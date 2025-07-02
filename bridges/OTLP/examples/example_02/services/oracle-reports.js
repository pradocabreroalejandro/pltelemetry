const express = require('express');
const cors = require('cors');
const { v4: uuidv4 } = require('uuid');

const app = express();
const PORT = process.env.SERVICE_PORT || 8001;
const SERVICE_NAME = 'Oracle Reports';

app.use(cors());
app.use(express.json());

// Service state simulation
let serviceState = {
    isHealthy: true,
    reportQueue: 0,
    processedReports: 0,
    lastReportTime: new Date(),
    errors: []
};

// Middleware to log all requests
app.use((req, res, next) => {
    console.log(`[${SERVICE_NAME}] ${new Date().toISOString()} - ${req.method} ${req.path}`);
    next();
});

// Health endpoint - core for heartbeat monitoring
app.get('/health', (req, res) => {
    const health = {
        service: SERVICE_NAME.toLowerCase().replace(' ', '-'),
        status: serviceState.isHealthy ? 'healthy' : 'unhealthy',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        memory: process.memoryUsage(),
        queue_size: serviceState.reportQueue,
        processed_count: serviceState.processedReports,
        last_activity: serviceState.lastReportTime,
        version: '1.0.0'
    };

    const statusCode = serviceState.isHealthy ? 200 : 503;
    res.status(statusCode).json(health);
});

// Generate report endpoint
app.post('/reports/generate', async (req, res) => {
    try {
        const { template, data, format = 'PDF' } = req.body;
        
        if (!template) {
            return res.status(400).json({
                error: 'Template is required',
                code: 'MISSING_TEMPLATE'
            });
        }

        // Simulate random failures (10% chance)
        if (Math.random() < 0.1) {
            serviceState.errors.push({
                timestamp: new Date(),
                error: 'Template compilation failed',
                template: template
            });
            throw new Error('Template compilation failed');
        }

        // Simulate processing time
        const processingTime = Math.random() * 3000 + 1000; // 1-4 seconds
        
        const jobId = uuidv4();
        serviceState.reportQueue++;
        serviceState.lastReportTime = new Date();

        // Simulate async processing
        setTimeout(() => {
            serviceState.reportQueue--;
            serviceState.processedReports++;
        }, processingTime);

        res.json({
            job_id: jobId,
            status: 'processing',
            template: template,
            format: format,
            estimated_completion: new Date(Date.now() + processingTime).toISOString()
        });

    } catch (error) {
        console.error(`[${SERVICE_NAME}] Error generating report:`, error.message);
        res.status(500).json({
            error: error.message,
            code: 'GENERATION_FAILED',
            timestamp: new Date().toISOString()
        });
    }
});

// Report status endpoint
app.get('/reports/:jobId/status', (req, res) => {
    const { jobId } = req.params;
    
    // Simulate job status lookup
    const statuses = ['processing', 'completed', 'failed'];
    const status = statuses[Math.floor(Math.random() * statuses.length)];
    
    res.json({
        job_id: jobId,
        status: status,
        progress: status === 'processing' ? Math.floor(Math.random() * 100) : 100,
        result_url: status === 'completed' ? `/reports/${jobId}/download` : null
    });
});

// Admin endpoints for testing failure scenarios
app.post('/admin/health/:status', (req, res) => {
    const { status } = req.params;
    serviceState.isHealthy = status === 'healthy';
    
    console.log(`[${SERVICE_NAME}] Health status changed to: ${status}`);
    res.json({
        message: `Service health set to ${status}`,
        previous_state: !serviceState.isHealthy
    });
});

app.get('/admin/errors', (req, res) => {
    res.json({
        errors: serviceState.errors,
        error_count: serviceState.errors.length
    });
});

app.post('/admin/simulate-crash', (req, res) => {
    console.log(`[${SERVICE_NAME}] Simulating crash - service will exit in 2 seconds`);
    res.json({ message: 'Service crash simulation initiated' });
    
    setTimeout(() => {
        console.log(`[${SERVICE_NAME}] CRASH SIMULATION - Exiting process`);
        process.exit(1);
    }, 2000);
});

// Start server
app.listen(PORT, () => {
    console.log(`\n🟢 ${SERVICE_NAME} running on port ${PORT}`);
    console.log(`   Health: http://localhost:${PORT}/health`);
    console.log(`   Reports: http://localhost:${PORT}/reports/generate`);
    console.log(`   Admin: http://localhost:${PORT}/admin/health/unhealthy`);
    console.log(`   Crash: http://localhost:${PORT}/admin/simulate-crash\n`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log(`\n🔴 ${SERVICE_NAME} shutting down gracefully...`);
    process.exit(0);
});