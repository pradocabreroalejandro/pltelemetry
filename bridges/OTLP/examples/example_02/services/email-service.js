const express = require('express');
const cors = require('cors');
const { v4: uuidv4 } = require('uuid');

const app = express();
const PORT = process.env.SERVICE_PORT || 8003;
const SERVICE_NAME = 'Email Service';

app.use(cors());
app.use(express.json());

let emailState = {
    isHealthy: true,
    emailsSent: 0,
    emailQueue: 0,
    lastEmailTime: new Date(),
    smtpConnected: true,
    errors: []
};

app.use((req, res, next) => {
    console.log(`[${SERVICE_NAME}] ${new Date().toISOString()} - ${req.method} ${req.path}`);
    next();
});

app.get('/health', (req, res) => {
    const health = {
        service: SERVICE_NAME.toLowerCase().replace(' ', '-'),
        status: emailState.isHealthy && emailState.smtpConnected ? 'healthy' : 'unhealthy',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        emails_sent: emailState.emailsSent,
        queue_size: emailState.emailQueue,
        smtp_connected: emailState.smtpConnected,
        last_email: emailState.lastEmailTime,
        version: '2.1.0'
    };

    const statusCode = health.status === 'healthy' ? 200 : 503;
    res.status(statusCode).json(health);
});

app.post('/send', async (req, res) => {
    try {
        const { to, subject, body, priority = 'normal' } = req.body;
        
        if (!to || !subject || !body) {
            return res.status(400).json({
                error: 'to, subject and body are required',
                code: 'MISSING_FIELDS'
            });
        }

        // Simulate SMTP disconnection (3% chance)
        if (Math.random() < 0.03) {
            emailState.smtpConnected = false;
            throw new Error('SMTP server connection lost');
        }

        // Simulate delivery delay based on priority
        const delays = { high: 500, normal: 1500, low: 3000 };
        const delay = delays[priority] || delays.normal;
        
        emailState.emailQueue++;
        const messageId = uuidv4();

        // Simulate async sending
        setTimeout(() => {
            emailState.emailQueue--;
            emailState.emailsSent++;
            emailState.lastEmailTime = new Date();
            
            // Random chance to reconnect SMTP if disconnected
            if (!emailState.smtpConnected && Math.random() < 0.7) {
                emailState.smtpConnected = true;
                console.log(`[${SERVICE_NAME}] SMTP connection restored`);
            }
        }, delay);

        res.json({
            message_id: messageId,
            status: 'queued',
            to: to,
            subject: subject,
            priority: priority,
            estimated_delivery: new Date(Date.now() + delay).toISOString()
        });

    } catch (error) {
        emailState.errors.push({
            timestamp: new Date(),
            error: error.message,
            recipient: req.body.to
        });
        
        console.error(`[${SERVICE_NAME}] Error sending email:`, error.message);
        res.status(500).json({
            error: error.message,
            code: 'SEND_FAILED'
        });
    }
});

// Admin endpoints
app.post('/admin/smtp/:status', (req, res) => {
    const { status } = req.params;
    emailState.smtpConnected = status === 'connected';
    
    console.log(`[${SERVICE_NAME}] SMTP status changed to: ${status}`);
    res.json({
        message: `SMTP status set to ${status}`,
        smtp_connected: emailState.smtpConnected
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

app.listen(PORT, () => {
    console.log(`\n🟢 ${SERVICE_NAME} running on port ${PORT}`);
    console.log(`   Health: http://localhost:${PORT}/health`);
    console.log(`   Send: http://localhost:${PORT}/send`);
    console.log(`   SMTP: http://localhost:${PORT}/admin/smtp/disconnected`);
    console.log(`   Crash: http://localhost:${PORT}/admin/simulate-crash\n`);
});
