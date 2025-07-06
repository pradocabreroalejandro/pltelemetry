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
   "title": "PLTelemetry - Database Health (Lite)",
   "tags": ["pltelemetry", "oracle", "database", "lite", "trends"],
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
       "title": "🚦 Health Status Trends",
       "type": "timeseries",
       "gridPos": {
         "h": 8,
         "w": 12,
         "x": 0,
         "y": 0
       },
       "targets": [
         {
           "expr": "pltelemetry_db_tablespace_usage_status_gauge{validation_type=\"TABLESPACE_USAGE\"} >= -1",
           "legendFormat": "Tablespace Health",
           "refId": "A",
           "interval": "30s"
         },
         {
           "expr": "pltelemetry_db_cpu_usage_status_gauge{validation_type=\"CPU_USAGE\"} >= -1",
           "legendFormat": "CPU Health",
           "refId": "B",
           "interval": "30s"
         },
         {
           "expr": "pltelemetry_db_memory_usage_status_gauge{validation_type=\"MEMORY_USAGE\"} >= -1",
           "legendFormat": "Memory Health",
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
       "title": "📊 Tablespaces Usage Trends",
       "type": "timeseries",
       "gridPos": {
         "h": 8,
         "w": 12,
         "x": 12,
         "y": 0
       },
       "targets": [
         {
           "expr": "pltelemetry_db_tablespace_usage_value_percentage{validation_type=\"TABLESPACE_USAGE\"} >= 80",
           "legendFormat": "{{target_identifier}} TS",
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
           "min": 80,
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
                 "value": 85
               },
               {
                 "color": "orange",
                 "value": 92
               },
               {
                 "color": "red",
                 "value": 96
               }
             ]
           }
         }
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
       "title": "🖥️ CPU & Memory Trends",
       "type": "timeseries",
       "gridPos": {
         "h": 8,
         "w": 12,
         "x": 0,
         "y": 8
       },
       "targets": [
         {
           "expr": "pltelemetry_db_cpu_usage_value_percentage{validation_type=\"CPU_USAGE\"} >= 0",
           "legendFormat": "CPU Usage %",
           "refId": "A",
           "interval": "30s"
         },
         {
           "expr": "pltelemetry_db_memory_usage_value_percentage{validation_type=\"MEMORY_USAGE\"} > 0",
           "legendFormat": "{{target_identifier}} Memory %",
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
             "axisLabel": "Usage %",
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
               "options": ".*CPU.*"
             },
             "properties": [
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
               "options": ".*Memory.*"
             },
             "properties": [
               {
                 "id": "color",
                 "value": {
                   "mode": "fixed",
                   "fixedColor": "purple"
                 }
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
       "title": "⚠️ Issues Trends",
       "type": "timeseries",
       "gridPos": {
         "h": 8,
         "w": 12,
         "x": 12,
         "y": 8
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
           "expr": "pltelemetry_db_validation_errors_count >= 0",
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
             "axisLabel": "Count",
             "axisPlacement": "auto",
             "drawStyle": "line",
             "fillOpacity": 25,
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
               "options": ".*Validation.*"
             },
             "properties": [
               {
                 "id": "color",
                 "value": {
                   "mode": "fixed",
                   "fixedColor": "yellow"
                 }
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
       "title": "👥 Sessions Trends",
       "type": "timeseries",
       "gridPos": {
         "h": 8,
         "w": 12,
         "x": 0,
         "y": 16
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
       "id": 6,
       "title": "📈 Performance Trends",
       "type": "timeseries",
       "gridPos": {
         "h": 8,
         "w": 12,
         "x": 12,
         "y": 16
       },
       "targets": [
         {
           "expr": "pltelemetry_db_cpu_time_per_call_value_centiseconds{validation_type=\"CPU_TIME_PER_CALL\"} >= 0",
           "legendFormat": "CPU Time per Call (cs)",
           "refId": "A",
           "interval": "30s"
         },
         {
           "expr": "pltelemetry_db_cpu_usage_per_txn_value_centiseconds{validation_type=\"CPU_USAGE_PER_TXN\"} >= 0",
           "legendFormat": "CPU per Transaction (cs)",
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
 "message": "PLTelemetry Database Health (Lite) - Fixed spanNulls for connected lines",
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