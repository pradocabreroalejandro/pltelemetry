#!/bin/bash
# =============================================================================
# PLTelemetry Database Health (Lite) - Clean Trends Dashboard (Fixed)
# Fixed spanNulls to connect graph points properly
# 
# Usage: ./import_lite_dashboard_fixed.sh <grafana_password>
# Example: ./import_lite_dashboard_fixed.sh admin
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

echo "🚀 Importing PLTelemetry Database Health (Lite) Dashboard - FIXED"
echo "🔐 Using password for user: $GRAFANA_USER"
echo "=================================================================="
echo "🔧 FIXED: spanNulls: true - connects graph points properly"
echo "📊 6 CLEAN TREND PANELS with connected lines"
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

# Test Grafana connection
echo "🔗 Testing Grafana connection..."
TEST_RESULT=$(grafana_api "GET" "health")

if echo "$TEST_RESULT" | grep -q "ok"; then
   echo "✅ Grafana connection successful"
else
   echo "❌ Cannot connect to Grafana at $GRAFANA_URL"
   echo "Response: $TEST_RESULT"
   exit 1
fi

# PLTelemetry Database Health (Lite) Dashboard - FIXED
PLT_LITE_DASHBOARD_FIXED='{
  "dashboard": {
    "id": null,
    "title": "PLTelemetry - Database Health (Lite WORKING! 🔥)",
    "tags": ["pltelemetry", "oracle", "database", "lite", "working", "real-metrics"],
    "style": "dark",
    "timezone": "browser",
    "editable": true,
    "graphTooltip": 1,
    "time": {
      "from": "now-1h",
      "to": "now"
    },
    "refresh": "30s",
    "panels": [
      {
        "id": 1,
        "title": "🚦 Health Status Trends (REAL DATA)",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 0
        },
        "targets": [
          {
            "expr": "pltelemetry_db_validation_status_gauge",
            "legendFormat": "{{instance_name}} Health",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_service_status_gauge",
            "legendFormat": "{{service_name}} Service",
            "refId": "B",
            "interval": "30s"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "Health Status",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 25,
              "lineWidth": 2,
              "pointSize": 4,
              "showPoints": "auto",
              "spanNulls": true,
              "thresholdsStyle": {
                "mode": "area"
              }
            },
            "unit": "short",
            "min": -1.2,
            "max": 1.2,
            "thresholds": {
              "mode": "absolute",
              "steps": [
                {
                  "color": "red",
                  "value": -1
                },
                {
                  "color": "yellow",
                  "value": 0
                },
                {
                  "color": "green",
                  "value": 1
                }
              ]
            },
            "mappings": [
              {
                "type": "value",
                "value": "-1",
                "text": "CRITICAL"
              },
              {
                "type": "value", 
                "value": "0",
                "text": "WARNING"
              },
              {
                "type": "value",
                "value": "0.5",
                "text": "PARTIAL"
              },
              {
                "type": "value",
                "value": "1",
                "text": "OK"
              }
            ]
          }
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull"],
            "displayMode": "list",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 2,
        "title": "🖥️ CPU Performance Trends",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 0
        },
        "targets": [
          {
            "expr": "pltelemetry_db_validation_cpu_usage_value_percentage",
            "legendFormat": "CPU Usage %",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_validation_db_cpu_ratio_value_percentage",
            "legendFormat": "DB CPU Ratio %",
            "refId": "B",
            "interval": "30s"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "CPU %",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 20,
              "lineWidth": 2,
              "pointSize": 4,
              "showPoints": "auto",
              "spanNulls": true,
              "thresholdsStyle": {
                "mode": "area"
              }
            },
            "unit": "percent",
            "min": 0,
            "thresholds": {
              "mode": "absolute",
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
                  "value": 90
                },
                {
                  "color": "red",
                  "value": 100
                }
              ]
            }
          },
          "overrides": [
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Ratio.*"
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
                  "value": 40
                },
                {
                  "id": "max",
                  "value": 200
                }
              ]
            }
          ]
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max"],
            "displayMode": "list",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 3,
        "title": "💾 Memory & Sorts Trends",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 8
        },
        "targets": [
          {
            "expr": "pltelemetry_db_validation_pga_memory_usage_value_percentage",
            "legendFormat": "PGA Memory %",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_validation_memory_sorts_count_value",
            "legendFormat": "Memory Sorts Count",
            "refId": "B",
            "interval": "30s"
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
              "drawStyle": "line",
              "fillOpacity": 15,
              "lineWidth": 2,
              "pointSize": 4,
              "showPoints": "auto",
              "spanNulls": true,
              "thresholdsStyle": {
                "mode": "line"
              }
            },
            "unit": "short",
            "min": 0
          },
          "overrides": [
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Memory.*"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "purple"
                  }
                },
                {
                  "id": "unit",
                  "value": "percent"
                },
                {
                  "id": "max",
                  "value": 100
                },
                {
                  "id": "custom.axisPlacement",
                  "value": "left"
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
                        "value": 75
                      },
                      {
                        "color": "orange",
                        "value": 85
                      },
                      {
                        "color": "red",
                        "value": 95
                      }
                    ]
                  }
                }
              ]
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Sorts.*"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "blue"
                  }
                },
                {
                  "id": "unit",
                  "value": "short"
                },
                {
                  "id": "custom.axisPlacement",
                  "value": "right"
                }
              ]
            }
          ]
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max"],
            "displayMode": "list",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 4,
        "title": "👥 Sessions Trends",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 8
        },
        "targets": [
          {
            "expr": "pltelemetry_db_validation_active_sessions_value_count",
            "legendFormat": "Active Sessions",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_validation_blocked_sessions_value_count",
            "legendFormat": "Blocked Sessions",
            "refId": "B",
            "interval": "30s"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "Sessions",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 15,
              "lineWidth": 2,
              "pointSize": 4,
              "showPoints": "auto",
              "spanNulls": true
            },
            "unit": "short",
            "min": 0
          },
          "overrides": [
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Active.*"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "green"
                  }
                }
              ]
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Blocked.*"
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
                  "value": 40
                }
              ]
            }
          ]
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max"],
            "displayMode": "list",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 5,
        "title": "🔥 Advanced CPU Metrics",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 16
        },
        "targets": [
          {
            "expr": "pltelemetry_db_validation_cpu_time_per_call_value_centiseconds > -1",
            "legendFormat": "CPU Time per Call (cs)",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_validation_cpu_usage_per_txn_value_centiseconds",
            "legendFormat": "CPU per Transaction (cs)",
            "refId": "B",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_validation_background_cpu_usage_value_cpu_per_sec",
            "legendFormat": "Background CPU/sec",
            "refId": "C",
            "interval": "30s"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "Centiseconds",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 20,
              "lineWidth": 2,
              "pointSize": 4,
              "showPoints": "auto",
              "spanNulls": true,
              "thresholdsStyle": {
                "mode": "line"
              }
            },
            "unit": "short",
            "min": 0,
            "thresholds": {
              "mode": "absolute",
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
            }
          },
          "overrides": [
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*per Call.*"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "red"
                  }
                }
              ]
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*per Transaction.*"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "orange"
                  }
                }
              ]
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Background.*"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "blue"
                  }
                },
                {
                  "id": "unit",
                  "value": "cps"
                },
                {
                  "id": "custom.axisPlacement",
                  "value": "right"
                }
              ]
            }
          ]
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max", "mean"],
            "displayMode": "list",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 6,
        "title": "🏢 Service Response Times",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 16
        },
        "targets": [
          {
            "expr": "pltelemetry_service_response_time_milliseconds",
            "legendFormat": "{{service_name}}",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_validation_response_time_ms_milliseconds",
            "legendFormat": "{{instance_name}} DB",
            "refId": "B",
            "interval": "30s"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "Response Time (ms)",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 15,
              "lineWidth": 2,
              "pointSize": 4,
              "showPoints": "auto",
              "spanNulls": true,
              "thresholdsStyle": {
                "mode": "line"
              }
            },
            "unit": "ms",
            "min": 0,
            "thresholds": {
              "mode": "absolute",
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
            }
          },
          "overrides": [
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*oracle-reports.*"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "red"
                  }
                }
              ]
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*weblogic.*"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "orange"
                  }
                }
              ]
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*grafana.*"
              },
              "properties": [
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "green"
                  }
                }
              ]
            }
          ]
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max", "mean"],
            "displayMode": "list",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      }
    ],
    "templating": {
      "list": [
        {
          "current": {
            "selected": false,
            "text": "All",
            "value": "$__all"
          },
          "hide": 0,
          "includeAll": true,
          "label": "Environment",
          "multi": false,
          "name": "environment",
          "options": [],
          "query": "label_values(pltelemetry_db_validation_cycle_completed_count, environment)",
          "refresh": 1,
          "regex": "",
          "skipUrlSync": false,
          "sort": 0,
          "type": "query"
        },
        {
          "current": {
            "selected": false,
            "text": "All",
            "value": "$__all"
          },
          "hide": 0,
          "includeAll": true,
          "label": "Tenant",
          "multi": true,
          "name": "tenant",
          "options": [],
          "query": "label_values(pltelemetry_service_response_time_milliseconds, tenant_id)",
          "refresh": 1,
          "regex": "",
          "skipUrlSync": false,
          "sort": 0,
          "type": "query"
        }
      ]
    }
  },
  "folderId": null,
  "message": "PLTelemetry Database Health (Lite WORKING!) - Real metrics edition 🔥",
  "overwrite": true
}'

echo "📊 Importing FIXED Lite Dashboard..."
IMPORT_RESULT=$(grafana_api "POST" "dashboards/db" "$PLT_LITE_DASHBOARD_FIXED")

# Check if import was successful
if echo "$IMPORT_RESULT" | grep -q "success"; then
  DASHBOARD_UID=$(echo "$IMPORT_RESULT" | grep -o '"uid":"[^"]*"' | cut -d'"' -f4)
  echo ""
  echo "✅ PLTelemetry Database Health (Lite) Dashboard FIXED!"
  echo "=================================================================="
  echo "🔧 FIXED ISSUE: spanNulls: true (was false)"
  echo "📈 Now all graph points connect properly"
  echo ""
  echo "📊 6 PANELS with connected trend lines:"
  echo "   🚦 Health Status Trends"
  echo "   📊 Tablespaces Usage Trends"
  echo "   🖥️ CPU & Memory Trends"
  echo "   ⚠️ Issues Trends"
  echo "   👥 Sessions Trends"
  echo "   📈 Performance Trends"
  echo ""
  echo "🌐 Dashboard URL: $GRAFANA_URL/d/$DASHBOARD_UID"
  echo ""
  echo "🎯 No more disconnected points - smooth trend lines!"
else
  echo "❌ Import error:"
  echo "$IMPORT_RESULT"
fi