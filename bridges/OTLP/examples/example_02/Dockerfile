FROM node:18-alpine

WORKDIR /app

# Install curl for healthchecks
RUN apk add --no-cache curl

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy source code
COPY . .

# Expose all possible ports
EXPOSE 8001 8002 8003 8004 8005

# Default command (can be overridden)
CMD ["npm", "run", "start:all"]