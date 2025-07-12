#!/bin/bash
echo "🚀 PLTelemetry Legacy Services Control Script"
echo "=============================================="

show_help() {
    echo "Usage: ./start.sh [COMMAND] [SERVICE]"
    echo ""
    echo "Commands:"
    echo " start [SERVICE]           Start a specific service or all services"
    echo " stop [SERVICE]            Stop a specific service or all services"
    echo " restart [SERVICE]         Restart a specific service or all services"
    echo " status                    Show status of all services"
    echo " logs [SERVICE]            Show logs for a specific service"
    echo " crash [SERVICE]           Simulate crash for a specific service"
    echo " stress [RPS] [SERVICE] [DURATION] Stress test a service"
    echo " throttle [SERVICE] [SEVERITY]     Throttle service resources"
    echo " unthrottle [SERVICE]      Restore service resources to normal"
    echo ""
    echo "Services:"
    echo " oracle-reports            Oracle Reports Service (port 8001)"
    echo " weblogic-erp             WebLogic ERP Service (port 8002)"
    echo " email-service            Email Service (port 8003)"
    echo " batch-processor          Batch Processing Service (port 8004)"
    echo " document-service         Document Generation Service (port 8005)"
    echo " financial-service        Financial API Service (port 3001)"
    echo " all                      All services"
    echo ""
    echo "Throttle Severity Levels:"
    echo " light                    50% CPU, 512MB RAM, 1GB Swap"
    echo " medium                   10% CPU, 256MB RAM, 512MB Swap (default)"
    echo " brutal                   5% CPU, 128MB RAM, 256MB Swap"
    echo ""
    echo "Examples:"
    echo " ./start.sh start all"
    echo " ./start.sh stop oracle-reports"
    echo " ./start.sh restart weblogic-erp"
    echo " ./start.sh crash email-service"
    echo " ./start.sh stress 100 oracle-reports 30"
    echo " ./start.sh throttle weblogic-erp medium"
    echo " ./start.sh unthrottle weblogic-erp"
}

case "$1" in
    "start")
        if [ "$2" = "all" ] || [ -z "$2" ]; then
            echo "🟢 Starting all services..."
            docker compose up -d
        else
            echo "🟢 Starting $2..."
            docker compose up -d "$2"
        fi
        ;;
    "stop")
        if [ "$2" = "all" ] || [ -z "$2" ]; then
            echo "🔴 Stopping all services..."
            docker compose down
        else
            echo "🔴 Stopping $2..."
            docker compose stop "$2"
        fi
        ;;
    "restart")
        if [ "$2" = "all" ] || [ -z "$2" ]; then
            echo "🔄 Restarting all services..."
            docker compose restart
        else
            echo "🔄 Restarting $2..."
            docker compose restart "$2"
        fi
        ;;
    "status")
        echo "📊 Service Status:"
        docker compose ps
        echo ""
        echo "🌐 Health Check URLs:"
        echo " Oracle Reports:   http://localhost:8001/health"
        echo " WebLogic ERP:     http://localhost:8002/health"
        echo " Email Service:    http://localhost:8003/health"
        echo " Batch Processor:  http://localhost:8004/health"
        echo " Document Service: http://localhost:8005/health"
        echo " Financial API:    http://localhost:3001/health"
        echo ""
        echo "🎯 Observability:"
        echo " Grafana:          http://localhost:3020 (admin/admin)"
        echo " Prometheus:       http://localhost:9090"
        echo " Tempo:            http://localhost:3200"
        echo ""
        echo "📈 Resource Usage:"
        docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}" | grep plt-
        ;;
    "logs")
        if [ -z "$2" ]; then
            echo "📋 Showing logs for all services..."
            docker compose logs -f
        else
            echo "📋 Showing logs for $2..."
            docker compose logs -f "$2"
        fi
        ;;
    "crash")
        if [ -z "$2" ]; then
            echo "❌ Please specify a service to crash"
            exit 1
        fi
        
        # Get the port for the service
        case "$2" in
            "oracle-reports") PORT=8001 ;;
            "weblogic-erp") PORT=8002 ;;
            "email-service") PORT=8003 ;;
            "batch-processor") PORT=8004 ;;
            "document-service") PORT=8005 ;;
            "financial-service") PORT=3001 ;;
            *) echo "❌ Unknown service: $2"; exit 1 ;;
        esac
        
        echo "💥 Simulating crash for $2 (port $PORT)..."
        curl -X POST "http://localhost:$PORT/admin/simulate-crash" 2>/dev/null
        echo "Service will crash in 2 seconds..."
        ;;
    "stress")
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "❌ Usage: ./start.sh stress [RPS] [SERVICE] [DURATION_SECONDS]"
            echo "Example: ./start.sh stress 100 oracle-reports 30"
            exit 1
        fi

        # Better bc check - try to actually use it
        if ! echo "1+1" | bc > /dev/null 2>&1; then
            echo "❌ 'bc' calculator is required for stress testing"
            echo "Install with: sudo apt-get install bc (Ubuntu/Debian) or brew install bc (macOS)"
            exit 1
        fi

        RPS=$2
        SERVICE=$3
        DURATION=${4:-30}  # Default 30 seconds if not specified

        # Get the port for the service
        case "$SERVICE" in
            "oracle-reports") PORT=8001 ;;
            "weblogic-erp") PORT=8002 ;;
            "email-service") PORT=8003 ;;
            "batch-processor") PORT=8004 ;;
            "document-service") PORT=8005 ;;
            "financial-service") PORT=3001 ;;
            *) echo "❌ Unknown service: $SERVICE"; exit 1 ;;
        esac

        INTERVAL=$(echo "scale=3; 1/$RPS" | bc -l)
        TOTAL_REQUESTS=$((RPS * DURATION))

        echo "🔥 Starting stress test:"
        echo "   Service: $SERVICE (port $PORT)"
        echo "   Rate: $RPS requests/second"
        echo "   Duration: $DURATION seconds"
        echo "   Total requests: $TOTAL_REQUESTS"
        echo "   Interval: ${INTERVAL}s"
        echo ""
        echo "💡 Watch the magic in Grafana: http://localhost:3020"
        echo ""

        # Background stress loop
        START_TIME=$(date +%s)
        for i in $(seq 1 $TOTAL_REQUESTS); do
            curl -s -o /dev/null "http://localhost:$PORT/health" &
            sleep $INTERVAL
            
            # Progress indicator every 10 requests
            if [ $((i % 10)) -eq 0 ]; then
                echo -n "."
            fi
            
            # Show progress every 100 requests
            if [ $((i % 100)) -eq 0 ]; then
                CURRENT_TIME=$(date +%s)
                ELAPSED=$((CURRENT_TIME - START_TIME))
                echo " [$i/$TOTAL_REQUESTS] ${ELAPSED}s elapsed"
            fi
        done

        echo ""
        echo "✅ Stress test completed! Check your Grafana dashboards 📊"
        echo "🎯 Look for response time spikes in the service metrics"
        ;;
    "throttle")
        if [ -z "$2" ]; then
            echo "❌ Please specify a service to throttle"
            echo "Usage: ./start.sh throttle [SERVICE] [SEVERITY]"
            echo "Severity: light, medium (default), brutal"
            exit 1
        fi
        
        SERVICE=$2
        SEVERITY=${3:-"medium"}  # Default to medium if not specified
        
        # Map service names to actual container names
        case "$SERVICE" in
            "oracle-reports") CONTAINER_NAME="plt-oracle-reports" ;;
            "weblogic-erp") CONTAINER_NAME="plt-weblogic-erp" ;;
            "email-service") CONTAINER_NAME="plt-email-service" ;;
            "batch-processor") CONTAINER_NAME="plt-batch-processor" ;;
            "document-service") CONTAINER_NAME="plt-document-service" ;;
            "financial-service") CONTAINER_NAME="plt-financial-service" ;;
            *) echo "❌ Unknown service: $SERVICE"; exit 1 ;;
        esac
        
        # Set resource limits based on severity
        case "$SEVERITY" in
            "light") 
                CPUS="0.5"
                MEMORY="512m"
                MEMORY_SWAP="1g"  # Swap = 2x memory
                echo "🐌 Applying LIGHT throttling to $SERVICE (50% CPU, 512MB RAM, 1GB Swap)..."
                ;;
            "medium") 
                CPUS="0.1"
                MEMORY="256m"
                MEMORY_SWAP="512m"  # Swap = 2x memory
                echo "🐌 Applying MEDIUM throttling to $SERVICE (10% CPU, 256MB RAM, 512MB Swap)..."
                ;;
            "brutal") 
                CPUS="0.05"
                MEMORY="128m"
                MEMORY_SWAP="256m"  # Swap = 2x memory
                echo "🐌 Applying BRUTAL throttling to $SERVICE (5% CPU, 128MB RAM, 256MB Swap)..."
                ;;
            *) 
                echo "❌ Unknown severity: $SEVERITY. Use: light, medium, brutal"
                exit 1
                ;;
        esac
        
        # Apply the throttling with debug info
        echo "🔧 Targeting container: $CONTAINER_NAME"
        
        if docker update --cpus="$CPUS" --memory="$MEMORY" --memory-swap="$MEMORY_SWAP" "$CONTAINER_NAME"; then
            echo "✅ $SERVICE successfully throttled to $SEVERITY mode"
            echo "💡 Monitor the impact in Grafana: http://localhost:3020"
            echo "🔧 To restore: ./start.sh unthrottle $SERVICE"
            echo ""
            echo "📊 New resource limits:"
            docker inspect "$CONTAINER_NAME" --format='  CPU: {{.HostConfig.CpuQuota}}/{{.HostConfig.CpuPeriod}} | Memory: {{.HostConfig.Memory}} | Swap: {{.HostConfig.MemorySwap}}' 2>/dev/null
        else
            echo "❌ Failed to throttle $SERVICE"
            echo "🔍 Current limits:"
            docker inspect "$CONTAINER_NAME" --format='  Memory: {{.HostConfig.Memory}} | Swap: {{.HostConfig.MemorySwap}}' 2>/dev/null
            echo ""
            echo "💡 Try running: docker update --cpus=$CPUS --memory=$MEMORY --memory-swap=$MEMORY_SWAP $CONTAINER_NAME"
        fi
        ;;
    "unthrottle")
        if [ -z "$2" ]; then
            echo "❌ Please specify a service to unthrottle"
            echo "Usage: ./start.sh unthrottle [SERVICE]"
            exit 1
        fi
        
        SERVICE=$2
        
        # Map service names to actual container names
        case "$SERVICE" in
            "oracle-reports") CONTAINER_NAME="plt-oracle-reports" ;;
            "weblogic-erp") CONTAINER_NAME="plt-weblogic-erp" ;;
            "email-service") CONTAINER_NAME="plt-email-service" ;;
            "batch-processor") CONTAINER_NAME="plt-batch-processor" ;;
            "document-service") CONTAINER_NAME="plt-document-service" ;;
            "financial-service") CONTAINER_NAME="plt-financial-service" ;;
            *) echo "❌ Unknown service: $SERVICE"; exit 1 ;;
        esac
        
        echo "🚀 Restoring $SERVICE to normal performance..."
        echo "🔧 Targeting container: $CONTAINER_NAME"
        
        if docker update --cpus="2.0" --memory="1g" --memory-swap="2g" "$CONTAINER_NAME"; then
            echo "✅ $SERVICE successfully restored to normal resources (2 CPUs, 1GB RAM, 2GB Swap)"
            echo "💡 Performance should improve in Grafana dashboards"
            echo ""
            echo "📊 Current resource limits:"
            docker inspect "$CONTAINER_NAME" --format='  CPU: {{.HostConfig.CpuQuota}}/{{.HostConfig.CpuPeriod}} | Memory: {{.HostConfig.Memory}} | Swap: {{.HostConfig.MemorySwap}}' 2>/dev/null
        else
            echo "❌ Failed to unthrottle $SERVICE"
            echo "🔍 Debug info:"
            echo "   Service: $SERVICE"
            echo "   Container: $CONTAINER_NAME"
            echo ""
            echo "🔍 Available containers:"
            docker ps --format "table {{.Names}}\t{{.Status}}" | grep plt-
        fi
        ;;
    "help"|"--help"|"-h")
        show_help
        ;;
    *)
        show_help
        ;;
esac