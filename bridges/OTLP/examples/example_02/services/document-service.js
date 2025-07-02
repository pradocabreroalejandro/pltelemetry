const express = require('express');
const cors = require('cors');

const app = express();
const PORT = process.env.SERVICE_PORT || 8005;
const SERVICE_NAME = 'Document Service';

app.use(cors());
app.use(express.json());

app.get('/health', (req, res) => {
    res.json({
        service: 'document-service',
        status: 'healthy',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        version: '1.5.2'
    });
});

app.listen(PORT, () => {
    console.log(`🟢 ${SERVICE_NAME} running on port ${PORT}`);
});
