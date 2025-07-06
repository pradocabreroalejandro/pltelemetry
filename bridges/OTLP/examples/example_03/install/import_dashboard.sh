#!/bin/bash
# =============================================================================
# PLTelemetry Database Monitoring Dashboard - MEGA SEXY UPGRADE! 🚀
# Fixed with REAL metrics from your Prometheus + new panels for everything
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

echo "🚀 Importing PLTelemetry Database Monitoring Dashboard - MEGA SEXY UPGRADE!"
echo "🔐 Using provided password for user: $GRAFANA_USER"
echo "=================================================================="
echo "🆕 NUEVAS MÉTRICAS INCLUIDAS:"
echo "   🚀 CPU Time per Call (centiseconds) - CRITICAL metric detected!"
echo "   📊 CPU Usage per Transaction"
echo "   🔄 Background CPU Usage"  
echo "   📈 Database CPU Ratio"
echo "   💾 Smart Memory handling (PGA=-1 filtered)"
echo "   🔧 Failed Jobs monitoring (14 detected!)"
echo "   📁 Tablespace crisis alerts (98.38% SYSTEM!)"
echo "✨ MEGA sexy dark theme with proper thresholds"
echo "🎯 Real-time validation performance"
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

# PLTelemetry Database Monitoring Dashboard - MEGA SEXY UPGRADE!
PLT_DB_DASHBOARD='{
  "dashboard": {
    "id": null,
    "title": "🗄️ PLTelemetry - Database Monitoring (MEGA SEXY UPGRADE 🚀)",
    "tags": ["pltelemetry", "oracle", "database", "monitoring", "sexy", "upgraded"],
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
        "title": "🚨 TABLESPACE CRISIS ALERT - Usage %",
        "type": "timeseries",
        "gridPos": {
          "h": 9,
          "w": 12,
          "x": 0,
          "y": 0
        },
        "targets": [
          {
            "expr": "pltelemetry_db_tablespace_usage_value_percentage{validation_type=\"TABLESPACE_USAGE\"} >= 0",
            "legendFormat": "{{target_identifier}} Tablespace",
            "refId": "A",
            "interval": "30s"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "Usage %",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 30,
              "lineWidth": 3,
              "pointSize": 8,
              "showPoints": "always",
              "spanNulls": false,
              "thresholdsStyle": {
                "mode": "area"
              }
            },
            "unit": "percent",
            "min": 0,
            "max": 100,
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
                  "value": 85
                },
                {
                  "color": "red",
                  "value": 95
                }
              ]
            }
          }
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max"],
            "displayMode": "table",
            "placement": "right",
            "showLegend": true
          },
          "tooltip": {
            "mode": "multi",
            "sort": "desc"
          }
        },
        "alert": {
          "alertRuleTags": {},
          "conditions": [
            {
              "evaluator": {
                "params": [95],
                "type": "gt"
              },
              "operator": {
                "type": "and"
              },
              "query": {
                "params": ["A", "5m", "now"]
              },
              "reducer": {
                "params": [],
                "type": "last"
              },
              "type": "query"
            }
          ],
          "executionErrorState": "alerting",
          "for": "5m",
          "frequency": "10s",
          "handler": 1,
          "name": "Tablespace Critical Usage",
          "noDataState": "no_data",
          "notifications": []
        }
      },
      {
        "id": 2,
        "title": "👥 Sessions Overview",
        "type": "timeseries",
        "gridPos": {
          "h": 9,
          "w": 12,
          "x": 12,
          "y": 0
        },
        "targets": [
          {
            "expr": "pltelemetry_db_active_sessions_value_count{validation_type=\"ACTIVE_SESSIONS\"} >= 0",
            "legendFormat": "Active Sessions",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_blocked_sessions_value_count{validation_type=\"BLOCKED_SESSIONS\"} >= 0",
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
              "fillOpacity": 20,
              "lineWidth": 2,
              "pointSize": 5,
              "showPoints": "auto",
              "spanNulls": false,
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
                  "value": 50
                }
              ]
            }
          ]
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max", "mean"],
            "displayMode": "table",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi",
            "sort": "desc"
          }
        }
      },
      {
        "id": 3,
        "title": "💾 Memory Usage (Smart Filtering)",
        "type": "timeseries",
        "gridPos": {
          "h": 9,
          "w": 12,
          "x": 0,
          "y": 9
        },
        "targets": [
          {
            "expr": "pltelemetry_db_memory_usage_value_percentage{validation_type=\"MEMORY_USAGE\"} > 0",
            "legendFormat": "{{target_identifier}} Memory",
            "refId": "A",
            "interval": "30s"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "Memory %",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 25,
              "lineWidth": 2,
              "pointSize": 5,
              "showPoints": "auto",
              "spanNulls": false,
              "thresholdsStyle": {
                "mode": "area"
              }
            },
            "unit": "percent",
            "min": 0,
            "max": 100,
            "thresholds": {
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
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max"],
            "displayMode": "table",
            "placement": "right"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 4,
        "title": "🚀 CPU Usage Overview %",
        "type": "timeseries",
        "gridPos": {
          "h": 9,
          "w": 12,
          "x": 12,
          "y": 9
        },
        "targets": [
          {
            "expr": "pltelemetry_db_cpu_usage_value_percentage{validation_type=\"CPU_USAGE\"} >= 0",
            "legendFormat": "Database CPU Usage",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_db_cpu_ratio_value_percentage{validation_type=\"DB_CPU_RATIO\"} >= 0",
            "legendFormat": "DB CPU Ratio",
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
              "fillOpacity": 30,
              "lineWidth": 3,
              "pointSize": 5,
              "showPoints": "auto",
              "spanNulls": false,
              "thresholdsStyle": {
                "mode": "area"
              }
            },
            "unit": "percent",
            "min": 0,
            "max": 100,
            "thresholds": {
              "mode": "absolute",
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
                  "value": 90
                }
              ]
            }
          }
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max", "mean"],
            "displayMode": "table",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 5,
        "title": "🔥 CRITICAL - CPU Time per Call (Centiseconds)",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 18
        },
        "targets": [
          {
            "expr": "pltelemetry_db_cpu_time_per_call_value_centiseconds{validation_type=\"CPU_TIME_PER_CALL\"} >= 0",
            "legendFormat": "CPU Time per Call",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_cpu_usage_per_txn_value_centiseconds{validation_type=\"CPU_USAGE_PER_TXN\"} >= 0",
            "legendFormat": "CPU per Transaction",
            "refId": "B",
            "interval": "30s"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "custom": {
              "axisLabel": "Centiseconds",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 40,
              "lineWidth": 3,
              "pointSize": 6,
              "showPoints": "always",
              "spanNulls": false,
              "thresholdsStyle": {
                "mode": "area"
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
            }
          ]
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max", "mean"],
            "displayMode": "table",
            "placement": "right"
          },
          "tooltip": {
            "mode": "multi"
          }
        },
        "alert": {
          "alertRuleTags": {},
          "conditions": [
            {
              "evaluator": {
                "params": [5000],
                "type": "gt"
              },
              "operator": {
                "type": "and"
              },
              "query": {
                "params": ["A", "5m", "now"]
              },
              "reducer": {
                "params": [],
                "type": "last"
              },
              "type": "query"
            }
          ],
          "executionErrorState": "alerting",
          "for": "2m",
          "frequency": "10s",
          "handler": 1,
          "name": "CPU Time per Call Critical",
          "noDataState": "no_data",
          "notifications": []
        }
      },
      {
        "id": 6,
        "title": "🔧 System Health Issues",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 18
        },
        "targets": [
          {
            "expr": "pltelemetry_db_failed_jobs_value_count{validation_type=\"FAILED_JOBS\"} >= 0",
            "legendFormat": "Failed Jobs",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_invalid_objects_value_count{validation_type=\"INVALID_OBJECTS\"} >= 0",
            "legendFormat": "Invalid Objects",
            "refId": "B",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_background_cpu_usage_value_cpu_per_sec{validation_type=\"BACKGROUND_CPU_USAGE\"} >= 0",
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
              "axisLabel": "Count",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 25,
              "lineWidth": 2,
              "pointSize": 5,
              "showPoints": "auto",
              "spanNulls": false
            },
            "unit": "short",
            "min": 0
          },
          "overrides": [
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Failed.*"
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
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Invalid.*"
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
                  "id": "custom.axisPlacement",
                  "value": "right"
                },
                {
                  "id": "unit",
                  "value": "cps"
                }
              ]
            }
          ]
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "max"],
            "displayMode": "table",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 7,
        "title": "🔧 Validation Performance Metrics",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 0,
          "y": 26
        },
        "targets": [
          {
            "expr": "pltelemetry_db_validation_cycle_duration_ms_milliseconds",
            "legendFormat": "Cycle Duration (ms)",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_validations_executed_count",
            "legendFormat": "Validations Executed",
            "refId": "B",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_validation_errors_count",
            "legendFormat": "Validation Errors",
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
              "axisLabel": "",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 20,
              "lineWidth": 2,
              "pointSize": 5,
              "showPoints": "auto",
              "spanNulls": false
            },
            "unit": "short",
            "min": 0
          },
          "overrides": [
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Duration.*"
              },
              "properties": [
                {
                  "id": "unit",
                  "value": "ms"
                },
                {
                  "id": "color",
                  "value": {
                    "mode": "fixed",
                    "fixedColor": "blue"
                  }
                }
              ]
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Errors.*"
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
                  "value": 50
                }
              ]
            }
          ]
        },
        "options": {
          "legend": {
            "calcs": ["lastNotNull", "mean", "max"],
            "displayMode": "table",
            "placement": "right"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 8,
        "title": "⚠️ Status Gauges (Smart Health Indicators)",
        "type": "timeseries",
        "gridPos": {
          "h": 8,
          "w": 12,
          "x": 12,
          "y": 26
        },
        "targets": [
          {
            "expr": "pltelemetry_db_tablespace_usage_status_gauge{validation_type=\"TABLESPACE_USAGE\"} >= -1",
            "legendFormat": "{{target_identifier}} TS Status",
            "refId": "A",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_active_sessions_status_gauge{validation_type=\"ACTIVE_SESSIONS\"} >= -1",
            "legendFormat": "Sessions Status",
            "refId": "B",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_cpu_usage_status_gauge{validation_type=\"CPU_USAGE\"} >= -1",
            "legendFormat": "CPU Status",
            "refId": "C",
            "interval": "30s"
          },
          {
            "expr": "pltelemetry_db_memory_usage_status_gauge{validation_type=\"MEMORY_USAGE\"} >= -1",
            "legendFormat": "{{target_identifier}} Mem Status",
            "refId": "D",
            "interval": "30s"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "palette-classic"
            },
            "custom": {
              "axisLabel": "Status",
              "axisPlacement": "auto",
              "drawStyle": "line",
              "fillOpacity": 30,
              "lineWidth": 3,
              "pointSize": 6,
              "showPoints": "always",
              "spanNulls": false
            },
            "unit": "short",
            "min": -1.5,
            "max": 1.5,
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
                "text": "FAILED"
              },
              {
                "type": "value", 
                "value": "0",
                "text": "WARNING"
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
            "displayMode": "table",
            "placement": "bottom"
          },
          "tooltip": {
            "mode": "multi"
          }
        }
      },
      {
        "id": 9,
        "title": "📊 System Health Overview (Real-time Stats)",
        "type": "stat",
        "gridPos": {
          "h": 6,
          "w": 24,
          "x": 0,
          "y": 34
        },
        "targets": [
          {
            "expr": "pltelemetry_db_tablespace_usage_value_percentage{validation_type=\"TABLESPACE_USAGE\",target_identifier=\"SYSTEM\"} >= 0",
            "legendFormat": "SYSTEM TS",
            "refId": "A"
          },
          {
            "expr": "pltelemetry_db_tablespace_usage_value_percentage{validation_type=\"TABLESPACE_USAGE\",target_identifier=\"USERS\"} >= 0",
            "legendFormat": "USERS TS", 
            "refId": "B"
          },
          {
            "expr": "pltelemetry_db_active_sessions_value_count{validation_type=\"ACTIVE_SESSIONS\"} >= 0",
            "legendFormat": "Sessions",
            "refId": "C"
          },
          {
            "expr": "pltelemetry_db_cpu_usage_value_percentage{validation_type=\"CPU_USAGE\"} >= 0",
            "legendFormat": "CPU",
            "refId": "D"
          },
          {
            "expr": "pltelemetry_db_failed_jobs_value_count{validation_type=\"FAILED_JOBS\"} >= 0",
            "legendFormat": "Failed Jobs",
            "refId": "E"
          },
          {
            "expr": "pltelemetry_db_cpu_time_per_call_value_centiseconds{validation_type=\"CPU_TIME_PER_CALL\"} >= 0",
            "legendFormat": "CPU/Call (cs)",
            "refId": "F"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "color": {
              "mode": "thresholds"
            },
            "custom": {
              "align": "center",
              "displayMode": "auto",
              "inspect": false
            },
            "unit": "percent",
            "min": 0,
            "max": 100,
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
                  "value": 85
                },
                {
                  "color": "red",
                  "value": 95
                }
              ]
            }
          },
          "overrides": [
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Sessions.*"
              },
              "properties": [
                {
                  "id": "unit",
                  "value": "short"
                },
                {
                  "id": "max",
                  "value": 200
                }
              ]
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*Failed.*"
              },
              "properties": [
                {
                  "id": "unit",
                  "value": "short"
                },
                {
                  "id": "max",
                  "value": 50
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
                        "value": 1
                      },
                      {
                        "color": "orange",
                        "value": 5
                      },
                      {
                        "color": "red",
                        "value": 10
                      }
                    ]
                  }
                }
              ]
            },
            {
              "matcher": {
                "id": "byRegexp",
                "options": ".*CPU/Call.*"
              },
              "properties": [
                {
                  "id": "unit",
                  "value": "short"
                },
                {
                  "id": "max",
                  "value": 10000
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
               }
             ]
           }
         ]
       },
       "options": {
         "colorMode": "background",
         "graphMode": "area",
         "justifyMode": "center",
         "orientation": "horizontal",
         "reduceOptions": {
           "calcs": ["lastNotNull"],
           "fields": "",
           "values": false
         },
         "textMode": "value_and_name",
         "wideLayout": true
       }
     },
     {
       "id": 10,
       "title": "🆕 Advanced CPU Metrics (New!)",
       "type": "timeseries",
       "gridPos": {
         "h": 8,
         "w": 24,
         "x": 0,
         "y": 40
       },
       "targets": [
         {
           "expr": "pltelemetry_db_cpu_time_per_call_value_centiseconds{validation_type=\"CPU_TIME_PER_CALL\"} >= 0",
           "legendFormat": "CPU Time per Call (centiseconds)",
           "refId": "A",
           "interval": "30s"
         },
         {
           "expr": "pltelemetry_db_cpu_usage_per_txn_value_centiseconds{validation_type=\"CPU_USAGE_PER_TXN\"} >= 0",
           "legendFormat": "CPU Usage per Transaction (centiseconds)",
           "refId": "B",
           "interval": "30s"
         },
         {
           "expr": "pltelemetry_db_background_cpu_usage_value_cpu_per_sec{validation_type=\"BACKGROUND_CPU_USAGE\"} >= 0",
           "legendFormat": "Background CPU per Second",
           "refId": "C",
           "interval": "30s"
         },
         {
           "expr": "pltelemetry_db_db_cpu_ratio_value_percentage{validation_type=\"DB_CPU_RATIO\"} >= 0",
           "legendFormat": "Database CPU Ratio (%)",
           "refId": "D",
           "interval": "30s"
         }
       ],
       "fieldConfig": {
         "defaults": {
           "color": {
             "mode": "palette-classic"
           },
           "custom": {
             "axisLabel": "Mixed Units",
             "axisPlacement": "auto",
             "drawStyle": "line",
             "fillOpacity": 25,
             "lineWidth": 2,
             "pointSize": 5,
             "showPoints": "auto",
             "spanNulls": false
           },
           "unit": "short",
           "min": 0
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
               },
               {
                 "id": "custom.axisPlacement",
                 "value": "left"
               },
               {
                 "id": "unit",
                 "value": "short"
               },
               {
                 "id": "custom.fillOpacity",
                 "value": 40
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
               },
               {
                 "id": "custom.axisPlacement",
                 "value": "left"
               },
               {
                 "id": "unit",
                 "value": "short"
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
                 "id": "custom.axisPlacement",
                 "value": "right"
               },
               {
                 "id": "unit",
                 "value": "cps"
               }
             ]
           },
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
                   "fixedColor": "green"
                 }
               },
               {
                 "id": "custom.axisPlacement",
                 "value": "right"
               },
               {
                 "id": "unit",
                 "value": "percent"
               },
               {
                 "id": "max",
                 "value": 100
               }
             ]
           }
         ]
       },
       "options": {
         "legend": {
           "calcs": ["lastNotNull", "max", "mean"],
           "displayMode": "table",
           "placement": "bottom"
         },
         "tooltip": {
           "mode": "multi",
           "sort": "desc"
         }
       }
     },
     {
       "id": 11,
       "title": "🎯 Validation Cycle Performance",
       "type": "stat",
       "gridPos": {
         "h": 4,
         "w": 24,
         "x": 0,
         "y": 48
       },
       "targets": [
         {
           "expr": "pltelemetry_db_validation_cycle_duration_ms_milliseconds",
           "legendFormat": "Cycle Duration",
           "refId": "A"
         },
         {
           "expr": "pltelemetry_db_validations_executed_count",
           "legendFormat": "Validations",
           "refId": "B"
         },
         {
           "expr": "pltelemetry_db_validation_errors_count",
           "legendFormat": "Errors",
           "refId": "C"
         },
         {
           "expr": "pltelemetry_db_validation_cycle_completed_count",
           "legendFormat": "Cycles",
           "refId": "D"
         }
       ],
       "fieldConfig": {
         "defaults": {
           "color": {
             "mode": "thresholds"
           },
           "custom": {
             "align": "center",
             "displayMode": "auto"
           },
           "unit": "short",
           "thresholds": {
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
                 "color": "red",
                 "value": 500
               }
             ]
           }
         },
         "overrides": [
           {
             "matcher": {
               "id": "byRegexp",
               "options": ".*Duration.*"
             },
             "properties": [
               {
                 "id": "unit",
                 "value": "ms"
               }
             ]
           },
           {
             "matcher": {
               "id": "byRegexp",
               "options": ".*Errors.*"
             },
             "properties": [
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
                       "color": "red",
                       "value": 1
                     }
                   ]
                 }
               }
             ]
           }
         ]
       },
       "options": {
         "colorMode": "background",
         "graphMode": "none",
         "justifyMode": "center",
         "orientation": "horizontal",
         "reduceOptions": {
           "calcs": ["lastNotNull"],
           "fields": "",
           "values": false
         },
         "textMode": "value_and_name"
       }
     }
   ],
   "annotations": {
     "list": [
       {
         "name": "Critical Issues",
         "datasource": {
           "type": "prometheus",
           "uid": "prometheus"
         },
         "enable": true,
         "expr": "pltelemetry_db_tablespace_usage_value_percentage{validation_type=\"TABLESPACE_USAGE\"} > 95 OR pltelemetry_db_cpu_time_per_call_value_centiseconds{validation_type=\"CPU_TIME_PER_CALL\"} > 5000 OR pltelemetry_db_failed_jobs_value_count{validation_type=\"FAILED_JOBS\"} > 10",
         "iconColor": "red",
         "name": "Critical Database Issues",
         "textFormat": "{{instance_name}} critical issue detected",
         "titleFormat": "🚨 Database Critical Alert"
       },
       {
         "name": "Performance Warnings",
         "datasource": {
           "type": "prometheus", 
           "uid": "prometheus"
         },
         "enable": true,
         "expr": "pltelemetry_db_cpu_usage_value_percentage{validation_type=\"CPU_USAGE\"} > 75 OR pltelemetry_db_db_cpu_ratio_value_percentage{validation_type=\"DB_CPU_RATIO\"} > 80",
         "iconColor": "orange",
         "name": "Performance Warnings",
         "textFormat": "{{instance_name}} performance warning",
         "titleFormat": "⚠️ Performance Alert"
       },
       {
         "name": "Validation Errors",
         "datasource": {
           "type": "prometheus",
           "uid": "prometheus"
         },
         "enable": true,
         "expr": "increase(pltelemetry_db_validation_errors_count[5m]) > 0",
         "iconColor": "purple",
         "name": "Validation Errors",
         "textFormat": "Validation cycle error detected",
         "titleFormat": "🔧 Validation Error"
       }
     ]
   },
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
         "label": "Instance",
         "multi": false,
         "name": "instance",
         "options": [],
         "query": "label_values(pltelemetry_db_validation_check_performed_count, exported_instance)",
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
 "message": "PLTelemetry Database Monitoring Dashboard - MEGA SEXY UPGRADE! 🚀 Fixed all metrics + new panels",
 "overwrite": true
}'

echo "📊 Importing MEGA SEXY UPGRADED database dashboard..."
IMPORT_RESULT=$(grafana_api "POST" "dashboards/db" "$PLT_DB_DASHBOARD")

# Check if import was successful
if echo "$IMPORT_RESULT" | grep -q "success"; then
   DASHBOARD_UID=$(echo "$IMPORT_RESULT" | grep -o '"uid":"[^"]*"' | cut -d'"' -f4)
   echo ""
   echo "🎉 PLTelemetry MEGA SEXY Database Dashboard imported successfully! 🚀"
   echo "=================================================================="
   echo "✨ NUEVO Y MEJORADO CON:"
   echo ""
   echo "🚨 CRITICAL PANELS:"
   echo "   📁 Tablespace Crisis Alert (SYSTEM: 98.38%, USERS: 95.3%)"
   echo "   🔥 CPU Time per Call (4965 cs) - CRITICAL THRESHOLD ALERTS!"
   echo "   🔧 Failed Jobs Monitor (14 detected)"
   echo ""
   echo "🆕 NEW ADVANCED METRICS:"
   echo "   📊 Database CPU Ratio (89%)"
   echo "   🔄 Background CPU Usage (0 cpu/sec)"
   echo "   💼 CPU Usage per Transaction (1.04 cs)"
   echo "   🎯 Smart Memory filtering (PGA=-1 handled)"
   echo ""
   echo "⚡ ENHANCED FEATURES:"
   echo "   🚨 Multi-level alerting (Critical, Warning, Validation)"
   echo "   📱 Responsive design with proper legends"
   echo "   🎨 Sexy color coding (red=critical, orange=warning)"
   echo "   📊 Mixed unit support (%, ms, cs, count, cpu/sec)"
   echo "   🔍 Smart filtering (>= 0 for valid data only)"
   echo "   📈 Real-time status gauges"
   echo ""
   echo "🌐 Dashboard URL: $GRAFANA_URL/d/$DASHBOARD_UID"
   echo "📋 Dashboard UID: $DASHBOARD_UID"
   echo ""
   echo "🎯 FIXED METRICS QUERIES:"
   echo "   ✅ pltelemetry_db_tablespace_usage_value_percentage >= 0"
   echo "   ✅ pltelemetry_db_cpu_time_per_call_value_centiseconds >= 0"
   echo "   ✅ pltelemetry_db_cpu_usage_per_txn_value_centiseconds >= 0"
   echo "   ✅ pltelemetry_db_background_cpu_usage_value_cpu_per_sec >= 0"
   echo "   ✅ pltelemetry_db_db_cpu_ratio_value_percentage >= 0"
   echo "   ✅ pltelemetry_db_memory_usage_value_percentage > 0 (smart PGA filter)"
   echo "   ✅ pltelemetry_db_failed_jobs_value_count >= 0"
   echo "   ✅ pltelemetry_db_invalid_objects_value_count >= 0"
   echo "   ✅ All status gauges with >= -1 filter"
   echo ""
   echo "🚨 ALERTING CONFIGURED:"
   echo "   🔴 Tablespace > 95% = CRITICAL"
   echo "   🔴 CPU Time per Call > 5000cs = CRITICAL"
   echo "   🟠 CPU Usage > 75% = WARNING"
   echo "   🟠 DB CPU Ratio > 80% = WARNING"
   echo "   🟣 Validation Errors = IMMEDIATE"
   echo ""
   echo "🎨 SEXY DASHBOARD FEATURES:"
   echo "   🌑 Dark theme with gradient fills"
   echo "   📊 11 intelligent panels"
   echo "   🔄 Auto-refresh 30s"
   echo "   📱 Mobile-responsive design"
   echo "   🎯 Instance template variable"
   echo "   📈 Real-time annotations"
   echo "   ✨ Background color-coded stats"
   echo ""
   echo "💥 Your database is DEFINITELY having issues - check those red panels!"
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