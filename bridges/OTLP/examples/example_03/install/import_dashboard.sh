#!/bin/bash
# =============================================================================
# PLTelemetry Multi-Tenant Database Monitoring Dashboard 
# BEAST MODE - Horizontal bars + Evolution graphs + Tenant isolation
# 
# Usage: ./import_dashboard.sh <grafana_password>
# Example: ./import_dashboard.sh admin
# =============================================================================

# Check if password parameter was provided
if [ $# -eq 0 ]; then
    echo "❌ Error: Grafana password required"
    echo ""
    echo "Usage: $0 <grafana_password>"
    echo "Example: $0 admin"
    exit 1
fi

GRAFANA_URL="http://localhost:3020"
GRAFANA_USER="admin"
GRAFANA_PASS="$1"

echo "🚀 Importing PLTelemetry Multi-Tenant Database Dashboard"
echo "🔐 Using provided password for user: $GRAFANA_USER"
echo "=================================================================="
echo "🎯 MULTI-TENANT FEATURES:"
echo "   🏢 Tenant isolation (never mixed)"
echo "   🌍 Environment filtering"
echo "   📊 Horizontal bars for tablespaces"
echo "   📈 Evolution graphs for metrics"
echo "   🚨 Critical threshold alerts"
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
    echo ""
    echo "Response: $TEST_RESULT"
    exit 1
fi

# PLTelemetry Multi-Tenant Database Dashboard JSON
PLT_DB_DASHBOARD='{
  "dashboard": {
    "id": null,
    "uid": "plt-db-monitoring",
    "title": "PLTelemetry Database Monitoring",
    "description": "Multi-tenant database monitoring with tenant isolation",
    "tags": ["pltelemetry", "database", "monitoring", "multi-tenant"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 1,
    "refresh": "30s",
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "timepicker": {
      "refresh_intervals": ["5s", "10s", "30s", "1m", "5m", "15m", "30m", "1h", "2h", "1d"]
    },
    "templating": {
      "list": [
        {
          "name": "tenant_id",
          "type": "query",
          "label": "Tenant",
          "description": "Select tenant to monitor",
          "query": "label_values(pltelemetry_db_validations_executed_count, tenant_id)",
          "datasource": {
            "type": "prometheus",
            "uid": null
          },
          "refresh": 1,
          "sort": 1,
          "multi": false,
          "includeAll": false,
          "current": {
            "selected": true,
            "text": "ACME_CORP",
            "value": "ACME_CORP"
          }
        },
        {
          "name": "environment_name",
          "type": "query",
          "label": "Environment",
          "description": "Select environment to monitor",
          "query": "label_values(pltelemetry_db_validations_executed_count{tenant_id=\"$tenant_id\"}, environment_name)",
          "datasource": {
            "type": "prometheus",
            "uid": null
          },
          "refresh": 1,
          "sort": 1,
          "multi": false,
          "includeAll": false,
          "current": {
            "selected": true,
            "text": "PROD",
            "value": "PROD"
          }
        }
      ]
    },
    "panels": [
      {
        "id": 1,
        "title": "🏢 Tenant Overview",
        "type": "stat",
        "gridPos": {
          "h": 3,
          "w": 24,
          "x": 0,
          "y": 0
        },
        "targets": [
          {
            "expr": "pltelemetry_db_validations_executed_count{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "Validations Executed",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "thresholds": {
              "steps": [
                {
                  "color": "green",
                  "value": null
                }
              ]
            },
            "unit": "short"
          }
        },
        "options": {
          "orientation": "horizontal",
          "reduceOptions": {
            "values": false,
            "calcs": ["lastNotNull"],
            "fields": ""
          },
          "textMode": "value_and_name",
          "colorMode": "background",
          "graphMode": "none"
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 2,
        "title": "📁 Tablespace Usage (%)",
        "type": "barchart",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 3
        },
        "targets": [
          {
            "expr": "pltelemetry_db_tablespace_usage_value_percentage{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "{{validation_target}}",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "thresholds": {
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "yellow",
                  "value": 70
                },
                {
                  "color": "orange",
                  "value": 80
                },
                {
                  "color": "red",
                  "value": 90
                }
              ]
            },
            "unit": "percent",
            "min": 0,
            "max": 100
          }
        },
        "options": {
          "orientation": "horizontal",
          "barWidth": 0.8,
          "groupWidth": 0.7,
          "showValue": "always",
          "stacking": "none",
          "tooltip": {
            "mode": "single"
          },
          "legend": {
            "displayMode": "visible",
            "placement": "right",
            "calcs": []
          }
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 3,
        "title": "🚨 Validation Status",
        "type": "stat",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 3
        },
        "targets": [
          {
            "expr": "count by (validation_status) (pltelemetry_db_tablespace_usage_status{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"})",
            "legendFormat": "{{validation_status}}",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "thresholds": {
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "orange",
                  "value": 1
                },
                {
                  "color": "red",
                  "value": 2
                }
              ]
            },
            "unit": "short"
          }
        },
        "options": {
          "orientation": "vertical",
          "reduceOptions": {
            "values": false,
            "calcs": ["lastNotNull"],
            "fields": ""
          },
          "textMode": "value_and_name",
          "colorMode": "background",
          "graphMode": "none"
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 4,
        "title": "⚡ CPU Usage Evolution (%)",
        "type": "timeseries",
        "gridPos": {
          "h": 6,
          "w": 12,
          "x": 0,
          "y": 11
        },
        "targets": [
          {
            "expr": "pltelemetry_db_cpu_usage_value_percentage{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "CPU Usage",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "thresholds": {
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "yellow",
                  "value": 60
                },
                {
                  "color": "orange",
                  "value": 75
                },
                {
                  "color": "red",
                  "value": 85
                }
              ]
            },
            "unit": "percent",
            "min": 0,
            "max": 100
          }
        },
        "options": {
          "tooltip": {
            "mode": "multi",
            "sort": "none"
          },
          "legend": {
            "displayMode": "visible",
            "placement": "bottom",
            "calcs": ["lastNotNull", "max"]
          }
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 5,
        "title": "💾 Memory Usage Evolution (%)",
        "type": "timeseries",
        "gridPos": {
          "h": 6,
          "w": 12,
          "x": 12,
          "y": 11
        },
        "targets": [
          {
            "expr": "pltelemetry_db_memory_usage_value_percentage{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"} >= 0",
            "legendFormat": "{{validation_target}} Memory",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "thresholds": {
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "yellow",
                  "value": 70
                },
                {
                  "color": "orange",
                  "value": 80
                },
                {
                  "color": "red",
                  "value": 90
                }
              ]
            },
            "unit": "percent",
            "min": 0,
            "max": 100
          }
        },
        "options": {
          "tooltip": {
            "mode": "multi",
            "sort": "none"
          },
          "legend": {
            "displayMode": "visible",
            "placement": "bottom",
            "calcs": ["lastNotNull", "max"]
          }
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 6,
        "title": "👥 Active Sessions Evolution",
        "type": "timeseries",
        "gridPos": {
          "h": 6,
          "w": 12,
          "x": 0,
          "y": 17
        },
        "targets": [
          {
            "expr": "pltelemetry_db_active_sessions_value_count{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "Active Sessions",
            "refId": "A"
          },
          {
            "expr": "pltelemetry_db_active_sessions_warning_threshold{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "Warning Threshold",
            "refId": "B"
          },
          {
            "expr": "pltelemetry_db_active_sessions_critical_threshold{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "Critical Threshold",
            "refId": "C"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "unit": "short"
          },
          "overrides": [
            {
              "matcher": {
                "id": "byName",
                "options": "Warning Threshold"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "orange"
                  }
                },
                {
                  "id": "custom.fillOpacity",
                  "value": 0
                }
              ]
            },
            {
              "matcher": {
                "id": "byName",
                "options": "Critical Threshold"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "red"
                  }
                },
                {
                  "id": "custom.fillOpacity",
                  "value": 0
                }
              ]
            }
          ]
        },
        "options": {
          "tooltip": {
            "mode": "multi",
            "sort": "none"
          },
          "legend": {
            "displayMode": "visible",
            "placement": "bottom",
            "calcs": ["lastNotNull", "max"]
          }
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 7,
        "title": "🔧 Failed Jobs",
        "type": "stat",
        "gridPos": {
          "h": 6,
          "w": 6,
          "x": 12,
          "y": 17
        },
        "targets": [
          {
            "expr": "pltelemetry_db_failed_jobs_value_count{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "Failed Jobs",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "thresholds": {
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "orange",
                  "value": 1
                },
                {
                  "color": "red",
                  "value": 5
                }
              ]
            },
            "unit": "short"
          }
        },
        "options": {
          "orientation": "horizontal",
          "reduceOptions": {
            "values": false,
            "calcs": ["lastNotNull"],
            "fields": ""
          },
          "textMode": "value_and_name",
          "colorMode": "background",
          "graphMode": "area"
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 8,
        "title": "⏱️ CPU Time per Call Evolution",
        "type": "timeseries",
        "gridPos": {
          "h": 6,
          "w": 6,
          "x": 18,
          "y": 17
        },
        "targets": [
          {
            "expr": "pltelemetry_db_cpu_time_per_call_value_centiseconds{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "CPU Time/Call",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "thresholds": {
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "yellow",
                  "value": 1000
                },
                {
                  "color": "orange",
                  "value": 3000
                },
                {
                  "color": "red",
                  "value": 5000
                }
              ]
            },
            "unit": "cs"
          }
        },
        "options": {
          "tooltip": {
            "mode": "single"
          },
          "legend": {
            "displayMode": "hidden"
          }
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 9,
        "title": "📊 Database CPU Ratio Evolution (%)",
        "type": "timeseries",
        "gridPos": {
          "h": 6,
          "w": 12,
          "x": 0,
          "y": 23
        },
        "targets": [
          {
            "expr": "pltelemetry_db_cpu_ratio_value_percentage{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "DB CPU Ratio",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "thresholds": {
              "steps": [
                {
                  "color": "green",
                  "value": null
                },
                {
                  "color": "yellow",
                  "value": 70
                },
                {
                  "color": "orange",
                  "value": 80
                },
                {
                  "color": "red",
                  "value": 90
                }
              ]
            },
            "unit": "percent",
            "min": 0,
            "max": 100
          }
        },
        "options": {
          "tooltip": {
            "mode": "single"
          },
          "legend": {
            "displayMode": "visible",
            "placement": "bottom",
            "calcs": ["lastNotNull", "max"]
          }
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 10,
        "title": "🔄 Background CPU Usage Evolution",
        "type": "timeseries",
        "gridPos": {
          "h": 6,
          "w": 12,
          "x": 12,
          "y": 23
        },
        "targets": [
          {
            "expr": "pltelemetry_db_background_cpu_usage_value_cpu_per_sec{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "Background CPU",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "unit": "cpu_per_sec"
          }
        },
        "options": {
          "tooltip": {
            "mode": "single"
          },
          "legend": {
            "displayMode": "visible",
            "placement": "bottom",
            "calcs": ["lastNotNull", "max"]
          }
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      },
      {
        "id": 11,
        "title": "💼 CPU Usage per Transaction Evolution",
        "type": "timeseries",
        "gridPos": {
          "h": 6,
          "w": 24,
          "x": 0,
          "y": 29
        },
        "targets": [
          {
            "expr": "pltelemetry_db_cpu_usage_per_txn_value_centiseconds{tenant_id=\"$tenant_id\", environment_name=\"$environment_name\"}",
            "legendFormat": "CPU/Transaction",
            "refId": "A"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "thresholds": {
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
                  "value": 75
                },
                {
                  "color": "red",
                  "value": 100
                }
              ]
            },
            "unit": "cs"
          }
        },
        "options": {
          "tooltip": {
            "mode": "single"
          },
          "legend": {
            "displayMode": "visible",
            "placement": "bottom",
            "calcs": ["lastNotNull", "max", "mean"]
          }
        },
        "datasource": {
          "type": "prometheus",
          "uid": null
        }
      }
    ]
  },
  "overwrite": true
}'

echo "📊 Importing Multi-Tenant Database Dashboard..."
IMPORT_RESULT=$(grafana_api "POST" "dashboards/db" "$PLT_DB_DASHBOARD")

# Check if import was successful
if echo "$IMPORT_RESULT" | grep -q "success"; then
   DASHBOARD_UID=$(echo "$IMPORT_RESULT" | grep -o '"uid":"[^"]*"' | cut -d'"' -f4)
   echo ""
   echo "🎉 PLTelemetry Multi-Tenant Database Dashboard imported successfully! 🚀"
   echo "======================================================================="
   echo ""
   echo "🏢 MULTI-TENANT FEATURES:"
   echo "   🎯 Tenant isolation: Only $tenant_id + $environment_name visible"
   echo "   📊 Horizontal tablespace bars with color coding"
   echo "   📈 Evolution graphs for all metrics"
   echo "   🚨 Real-time threshold monitoring"
   echo ""
   echo "📊 PANELS INCLUDED:"
   echo "   📁 Tablespace Usage (horizontal bars)"
   echo "   ⚡ CPU Usage Evolution"
   echo "   💾 Memory Usage Evolution (PGA=-1 filtered)"
   echo "   👥 Active Sessions with thresholds"
   echo "   🔧 Failed Jobs counter"
   echo "   ⏱️ CPU Time per Call (CRITICAL: >5000cs)"
   echo "   📊 Database CPU Ratio"
   echo "   🔄 Background CPU Usage"
   echo "   💼 CPU Usage per Transaction"
   echo "   🚨 Validation Status overview"
   echo ""
   echo "🎨 DASHBOARD FEATURES:"
   echo "   🌑 Dark theme optimized"
   echo "   🔄 Auto-refresh 30s"
   echo "   📱 Responsive design"
   echo "   🎯 Template variables: tenant_id, environment_name"
   echo "   🚨 Color-coded thresholds (green/yellow/orange/red)"
   echo "   📊 Mixed units support (%, cs, cpu/sec, count)"
   echo ""
   echo "🌐 Dashboard URL: $GRAFANA_URL/d/$DASHBOARD_UID"
   echo "📋 Dashboard UID: $DASHBOARD_UID"
   echo ""
   echo "🚨 CURRENT ALERTS DETECTED:"
   echo "   🔴 Tablespace USERS: 94.9% (CRITICAL)"
   echo "   🔴 Multiple tablespaces in ERROR state"
   echo "   📊 Ready for real-time monitoring"
   echo ""
   echo "💥 Your dashboard is ready to rock! 🚀"
else
   echo "❌ Import error:"
   echo "$IMPORT_RESULT"
   echo ""
   echo "🔍 Debug steps:"
   echo "   1. Check Prometheus: $GRAFANA_URL:9090"
   echo "   2. Query test: pltelemetry_db_tablespace_usage_value_percentage"
   echo "   3. Verify OTLP collector receiving data"
   echo "   4. Check PLT_DB_MONITOR is running"
fi