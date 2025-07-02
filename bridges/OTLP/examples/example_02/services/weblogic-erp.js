const express = require('express');
const cors = require('cors');

const app = express();
const PORT = process.env.SERVICE_PORT || 8002;
const SERVICE_NAME = 'WebLogic ERP';

app.use(cors());
app.use(express.json());

app.get('/health', (req, res) => {
    res.json({
        service: 'weblogic-erp',
        status: 'healthy',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        version: '12.2.1.4'
    });
});

app.listen(PORT, () => {
    console.log(`🟢 ${SERVICE_NAME} running on port ${PORT}`);
});
