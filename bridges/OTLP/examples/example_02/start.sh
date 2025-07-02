#!/bin/bash

echo "🚀 PLTelemetry Legacy Services Control Script"
echo "=============================================="

show_help() {
    echo "Usage: ./start.sh [COMMAND] [SERVICE]"
    echo ""
    echo "Commands:"
    echo "  start [SERVICE]     Start a specific service or all services"
    echo "  stop [SERVICE]      Stop a specific service or all services" 
    echo "  restart [SERVICE]   Restart a specific service or all services"
    echo "  status              Show status of all services"
    echo "  logs [SERVICE]      Show logs for a specific service"
    echo "  crash [SERVICE]     Simulate crash for a specific service"
    echo ""
    echo "Services:"
    echo "  oracle-reports      Oracle Reports Service (port 8001)"
    echo "  weblogic-erp        WebLogic ERP Service (port 8002)" 
    echo "  email-service       Email Service (port 8003)"
    echo "  batch-processor     Batch Processing Service (port 8004)"
    echo "  document-service    Document Generation Service (port 8005)"
    echo "  all                 All services"
    echo ""
    echo "Examples:"
    echo "  ./start.sh start all"
    echo "  ./start.sh stop oracle-reports"
    echo "  ./start.sh restart weblogic-erp"
    echo "  ./start.sh crash email-service"
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
        echo "   Oracle Reports: http://localhost:8001/health"
        echo "   WebLogic ERP:   http://localhost:8002/health"
        echo "   Email Service:  http://localhost:8003/health"
        echo "   Batch Proc:     http://localhost:8004/health"
        echo "   Doc Service:    http://localhost:8005/health"
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
            *) echo "❌ Unknown service: $2"; exit 1 ;;
        esac
        
        echo "💥 Simulating crash for $2 (port $PORT)..."
        curl -X POST "http://localhost:$PORT/admin/simulate-crash" 2>/dev/null
        echo "Service will crash in 2 seconds..."
        ;;
    "help"|"--help"|"-h")
        show_help
        ;;
    *)
        show_help
        ;;
esac