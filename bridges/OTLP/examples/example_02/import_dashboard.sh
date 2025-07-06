#!/bin/bash
# =============================================================================
# PLTelemetry Service Status Dashboard - Import Script
# 
# Usage: ./import_dashboard.sh <grafana_password>
# Example: ./import_dashboard.sh mySecretPassword123
# =============================================================================

# Check if password parameter was provided
if [ $# -eq 0 ]; then
    echo "❌ Error: Grafana password required"
    echo ""
    echo "Usage: $0 <grafana_password>"
    echo "Example: $0 mySecretPassword123"
    echo ""
    echo "🔒 Security note: Password is passed as parameter to avoid hardcoding"
    exit 1
fi

GRAFANA_URL="http://localhost:3020"
GRAFANA_USER="admin"
GRAFANA_PASS="$1"

echo "🎯 Importing PLTelemetry Service Status Dashboard..."
echo "🔐 Using provided password for user: $GRAFANA_USER"
echo "=================================================="
echo "📋 Dynamic table with automatic services"
echo "🟢 Up/Down status with colors"
echo "⏱️ Response times included"
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

# PLTelemetry Service Status Dashboard
PLT_SERVICE_DASHBOARD='{
  "dashboard": {
    "id": null,
    "title": "🎯 PLTelemetry - Service Status",
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
        "title": "Service Status Overview",
        "type": "table",
        "gridPos": {
          "h": 12,
          "w": 24,
          "x": 0,
          "y": 0
        },
        "targets": [
          {
            "expr": "pltelemetry_service_status_gauge",
            "format": "table",
            "instant": true,
            "refId": "A"
          },
          {
            "expr": "pltelemetry_service_response_time_ms_milliseconds",
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
                "criticality 1": true,
                "criticality 2": true,
                "endpoint_port 1": true,
                "endpoint_port 2": true,
                "exported_instance": true,
                "exported_job": true,
                "instance": true,
                "job": true,
                "otel_scope_name": true,
                "otel_scope_version": true,
                "source": true,
                "Time": true,
                "Time 1": true,
                "Time 2": true
              },
              "indexByName": {
                "service_name": 0,
                "Value #A": 1,
                "criticality": 2,
                "endpoint_port": 3,
                "Value #B": 4
              },
              "renameByName": {
                "service_name": "Service Name",
                "Value #A": "Status",
                "Value #B": "Response Time (ms)",
                "criticality": "Criticality",
                "endpoint_port": "Port"
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
            },
            "mappings": [
              {
                "options": {
                  "0": {
                    "color": "red",
                    "index": 0,
                    "text": "🔴 DOWN"
                  },
                  "1": {
                    "color": "green",
                    "index": 1,
                    "text": "🟢 UP"
                  }
                },
                "type": "value"
              }
            ],
            "color": {
              "mode": "thresholds"
            },
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "red",
                  "value": null
                },
                {
                  "color": "green",
                  "value": 1
                }
              ]
            }
          },
          "overrides": [
            {
              "matcher": {
                "id": "byName",
                "options": "Service Name"
              },
              "properties": [
                {
                  "id": "custom.width",
                  "value": 200
                },
                {
                  "id": "custom.align",
                  "value": "left"
                }
              ]
            },
            {
              "matcher": {
                "id": "byName",
                "options": "Status"
              },
              "properties": [
                {
                  "id": "custom.width",
                  "value": 120
                },
                {
                  "id": "custom.align",
                  "value": "center"
                },
                {
                  "id": "custom.displayMode",
                  "value": "color-background"
                }
              ]
            },
            {
              "matcher": {
                "id": "byName",
                "options": "Response Time (ms)"
              },
              "properties": [
                {
                  "id": "custom.width",
                  "value": 150
                },
                {
                  "id": "custom.align",
                  "value": "right"
                },
                {
                  "id": "unit",
                  "value": "ms"
                },
                {
                  "id": "color",
                  "value": {
                    "mode": "thresholds"
                  }
                },
                {
                  "id": "thresholds",
                  "value": {
                    "mode": "absolute",
                    "steps": [
                      {
                        "color": "green",
                        "value": null
                      },
                      {
                        "color": "yellow",
                        "value": 100
                      },
                      {
                        "color": "orange",
                        "value": 500
                      },
                      {
                        "color": "red",
                        "value": 1000
                      }
                    ]
                  }
                },
                {
                  "id": "custom.displayMode",
                  "value": "color-background"
                },
                {
                  "id": "decimals",
                  "value": 2
                }
              ]
            },
            {
              "matcher": {
                "id": "byName",
                "options": "Criticality"
              },
              "properties": [
                {
                  "id": "custom.width",
                  "value": 100
                },
                {
                  "id": "mappings",
                  "value": [
                    {
                      "options": {
                        "HIGH": {
                          "color": "red",
                          "index": 0,
                          "text": "🔥 HIGH"
                        },
                        "MEDIUM": {
                          "color": "orange",
                          "index": 1,
                          "text": "⚠️ MEDIUM"
                        },
                        "LOW": {
                          "color": "yellow",
                          "index": 2,
                          "text": "⚡ LOW"
                        },
                        "VERY_LOW": {
                          "color": "blue",
                          "index": 3,
                          "text": "ℹ️ VERY_LOW"
                        }
                      },
                      "type": "value"
                    }
                  ]
                }
              ]
            }
          ]
        },
        "options": {
          "showHeader": true,
          "sortBy": [
            {
              "desc": false,
              "displayName": "Service Name"
            }
          ]
        }
      },
      {
        "id": 2,
        "title": "Response Time Evolution (Last 15 min)",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 24,
          "x": 0,
          "y": 12
        },
        "targets": [
          {
            "expr": "pltelemetry_service_response_time_ms_milliseconds > -1",
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
              "axisLabel": "",
              "axisPlacement": "auto",
              "barAlignment": 0,
              "drawStyle": "line",
              "fillOpacity": 10,
              "gradientMode": "none",
              "hideFrom": {
                "legend": false,
                "tooltip": false,
                "vis": false
              },
              "lineInterpolation": "linear",
              "lineWidth": 2,
              "pointSize": 5,
              "scaleDistribution": {
                "type": "linear"
              },
              "showPoints": "never",
              "spanNulls": false,
              "stacking": {
                "group": "A",
                "mode": "none"
              },
              "thresholdsStyle": {
                "mode": "off"
              }
            },
            "mappings": [],
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
            },
            "unit": "ms"
          },
          "overrides": []
        },
        "options": {
          "legend": {
            "calcs": [],
            "displayMode": "table",
            "placement": "right"
          },
          "tooltip": {
            "mode": "single",
            "sort": "none"
          }
        }
      }
    ]
  },
  "folderId": null,
  "message": "PLTelemetry Service Status Dashboard - Dynamic services from metrics with response times",
  "overwrite": true
}'

echo "📊 Importing dashboard..."
IMPORT_RESULT=$(grafana_api "POST" "dashboards/db" "$PLT_SERVICE_DASHBOARD")

# Check if import was successful
if echo "$IMPORT_RESULT" | grep -q "success"; then
    DASHBOARD_UID=$(echo "$IMPORT_RESULT" | grep -o '"uid":"[^"]*"' | cut -d'"' -f4)
    echo ""
    echo "🎉 PLTelemetry Service Dashboard imported successfully!"
    echo "===================================================="
    echo "📋 Dynamic table: ✅"
    echo "🔄 Auto-refresh 30s: ✅"
    echo "🎨 Status colors: ✅"
    echo "⏱️ Response times with colors: ✅"
    echo "📈 Evolution chart (15min): ✅"
    echo "📊 Queries: status + response_time_ms (filtered > -1)"
    echo ""
    echo "🌐 Dashboard URL: $GRAFANA_URL/d/$DASHBOARD_UID"
    echo "📋 Dashboard UID: $DASHBOARD_UID"
else
    echo "❌ Import error:"
    echo "$IMPORT_RESULT"
    echo ""
    echo "🔍 Common issues:"
    echo "   - Check if metrics 'pltelemetry_service_status_gauge' exist in Prometheus"
    echo "   - Verify Prometheus datasource is configured in Grafana"
    echo "   - Ensure metrics are being scraped from OTEL collector"
fi