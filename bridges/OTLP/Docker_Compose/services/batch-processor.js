const express = require('express');
const cors = require('cors');

const app = express();
const PORT = process.env.SERVICE_PORT || 8004;
const SERVICE_NAME = 'Batch Processor';

app.use(cors());
app.use(express.json());

app.get('/health', (req, res) => {
    res.json({
        service: 'batch-processor',
        status: 'healthy',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        version: '3.1.0'
    });
});

app.listen(PORT, () => {
    console.log(`🟢 ${SERVICE_NAME} running on port ${PORT}`);
});
