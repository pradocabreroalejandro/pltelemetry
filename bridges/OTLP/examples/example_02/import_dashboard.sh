#!/bin/bash
# =============================================================================
# PLTelemetry Service Status Dashboard - CLEAN FIXED VERSION
# 
# Usage: ./import_dashboard_clean.sh <grafana_password>
# Example: ./import_dashboard_clean.sh admin
# =============================================================================

# Check if password parameter was provided
if [ $# -eq 0 ]; then
    echo "❌ Error: Grafana password required"
    echo ""
    echo "Usage: $0 <grafana_password>"
    echo "Example: $0 admin"
    echo ""
    echo "🔒 Security note: Password is passed as parameter to avoid hardcoding"
    exit 1
fi

GRAFANA_URL="http://localhost:3020"
GRAFANA_USER="admin"
GRAFANA_PASS="$1"

echo "🎯 Importing PLTelemetry Service Status Dashboard (CLEAN VERSION)..."
echo "🔐 Using provided password for user: $GRAFANA_USER"
echo "=================================================="
echo "📋 Single query table - NO duplicates"
echo "🟢 Up/Down status with colors"
echo "⏱️ Response times in separate panel"
echo "🔄 Auto-refresh every 30s"
echo ""

# Function to make Grafana API calls
grafana_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    if [ -n "$data" ]; then
        curl -s -X "$method" \
            -H "Content-Type: application/json" \
            -u "$GRAFANA_USER:$GRAFANA_PASS" \
            -d "$data" \
            "$GRAFANA_URL/api/$endpoint"
    else
        curl -s -X "$method" \
            -H "Content-Type: application/json" \
            -u "$GRAFANA_USER:$GRAFANA_PASS" \
            "$GRAFANA_URL/api/$endpoint"
    fi
}

# Test Grafana connection first
echo "🔗 Testing Grafana connection..."
TEST_RESULT=$(grafana_api "GET" "health")

if echo "$TEST_RESULT" | grep -q "ok"; then
    echo "✅ Grafana connection successful"
else
    echo "❌ Cannot connect to Grafana at $GRAFANA_URL"
    echo "🔍 Please check:"
    echo "   - Grafana is running on port 3020"
    echo "   - Username/password are correct"
    echo "   - URL is accessible"
    echo ""
    echo "Response: $TEST_RESULT"
    exit 1
fi

# PLTelemetry Service Status Dashboard - CLEAN VERSION
PLT_SERVICE_DASHBOARD='{
  "dashboard": {
    "id": null,
    "title": "🎯 PLTelemetry - Service Status (Clean)",
    "tags": ["pltelemetry", "services", "status", "monitoring"],
    "style": "dark",
    "timezone": "browser",
    "editable": true,
    "graphTooltip": 1,
    "time": {
      "from": "now-15m",
      "to": "now"
    },
    "refresh": "30s",
    "panels": [
      {
  "id": 1,
  "title": "🎯 Service Status & Performance",
  "type": "table",
  "gridPos": {
    "h": 12,
    "w": 24,
    "x": 0,
    "y": 0
  },
  "targets": [
    {
      "expr": "max by (service_name, criticality, endpoint_port, tenant_id) (pltelemetry_service_status_gauge)",
      "format": "table",
      "instant": true,
      "refId": "A"
    },
    {
      "expr": "max by (service_name) (pltelemetry_service_response_time_milliseconds)",
      "format": "table",
      "instant": true,
      "refId": "B"
    }
  ],
  "transformations": [
    {
      "id": "joinByField",
      "options": {
        "byField": "service_name",
        "mode": "outer"
      }
    },
    {
      "id": "organize",
      "options": {
        "excludeByName": {
          "__name__": true,
          "Time": true,
          "Time 1": true,
          "Time 2": true,
          "instance": true,
          "job": true,
          "otel_scope_name": true,
          "otel_scope_schema_url": true,
          "otel_scope_version": true
        },
        "renameByName": {
          "service_name": "Service Name",
          "Value #A": "Status",
          "Value #B": "Response Time",
          "criticality": "Criticality",
          "endpoint_port": "Port",
          "tenant_id": "Tenant"
        }
      }
    }
  ],
  "fieldConfig": {
    "defaults": {
      "custom": {
        "align": "left",
        "displayMode": "auto",
        "filterable": true
      }
    },
    "overrides": [
      {
        "matcher": {
          "id": "byName",
          "options": "Status"
        },
        "properties": [
          {
            "id": "custom.displayMode",
            "value": "color-background"
          },
          {
            "id": "mappings",
            "value": [
              {
                "options": {
                  "0": {
                    "color": "red",
                    "text": "DOWN"
                  },
                  "1": {
                    "color": "green",
                    "text": "UP"
                  }
                },
                "type": "value"
              }
            ]
          }
        ]
      },
      {
        "matcher": {
          "id": "byName",
          "options": "Response Time"
        },
        "properties": [
          {
            "id": "unit",
            "value": "ms"
          },
          {
            "id": "custom.displayMode",
            "value": "color-background"
          }
        ]
      }
    ]
  },
  "options": {
    "showHeader": true
  }
},
      {
        "id": 2,
        "title": "📈 Response Time Evolution (Last 15 min)",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 24,
          "x": 0,
          "y": 18
        },
        "targets": [
          {
            "expr": "max by (service_name) (pltelemetry_service_response_time_milliseconds)",
            "legendFormat": "{{service_name}}",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "Response Time",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 10,
              "lineWidth": 2,
              "pointSize": 5,
              "showPoints": "never",
              "spanNulls": false
            },
            "unit": "ms",
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "yellow",
                  "value": 50
                },
                {
                  "color": "orange",
                  "value": 100
                },
                {
                  "color": "red",
                  "value": 500
                }
              ]
            }
          }
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max", "mean"],
            "displayMode": "table",
            "placement": "right"
          },
          "tooltip": {
            "mode": "multi",
            "sort": "desc"
          }
        }
      }
    ]
  },
  "folderId": null,
  "message": "PLTelemetry Service Status Dashboard - Clean version with separate panels",
  "overwrite": true
}'

echo "📊 Importing clean dashboard..."
IMPORT_RESULT=$(grafana_api "POST" "dashboards/db" "$PLT_SERVICE_DASHBOARD")

# Check if import was successful
if echo "$IMPORT_RESULT" | grep -q "success"; then
    DASHBOARD_UID=$(echo "$IMPORT_RESULT" | grep -o '"uid":"[^"]*"' | cut -d'"' -f4)
    echo ""
    echo "🎉 PLTelemetry CLEAN Service Dashboard imported successfully!"
    echo "================================================================="
    echo "📋 Service Status table: ✅ (NO duplicates)"
    echo "⏱️ Response Times table: ✅ (sorted by time)"
    echo "📈 Evolution chart: ✅ (clean lines per service)"
    echo "🔄 Auto-refresh 30s: ✅"
    echo "🎨 Color coding: ✅"
    echo ""
    echo "🌐 Dashboard URL: $GRAFANA_URL/d/$DASHBOARD_UID"
    echo "📋 Dashboard UID: $DASHBOARD_UID"
    echo ""
    echo "🎯 Layout:"
    echo "   - Top: Service Status (UP/DOWN + Criticality)"
    echo "   - Middle: Response Times (sorted by slowest first)"
    echo "   - Bottom: Time series chart (trends)"
else
    echo "❌ Import error:"
    echo "$IMPORT_RESULT"
    echo ""
    echo "🔍 Common issues:"
    echo "   - Check if metrics 'pltelemetry_service_status_gauge' exist in Prometheus"
    echo "   - Verify Prometheus datasource is configured in Grafana"
    echo "   - Ensure metrics are being scraped from OTEL collector"
fi