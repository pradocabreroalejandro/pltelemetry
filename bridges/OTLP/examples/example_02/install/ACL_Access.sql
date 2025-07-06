-- Connect as DBA (SYS or SYSTEM)
BEGIN
  -- Create ACL for PLTelemetry heartbeat monitoring
  DBMS_NETWORK_ACL_ADMIN.CREATE_ACL(
    acl         => 'pltelemetry_heartbeat_acl.xml',
    description => 'PLTelemetry Heartbeat Monitor ACL',
    principal   => 'PLTELEMETRY',  -- Change this to your actual schema name
    is_grant    => TRUE,
    privilege   => 'connect'
  );
  
  -- Assign ACL to all your service hosts
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl  => 'pltelemetry_heartbeat_acl.xml',
    host => 'example_02-oracle-reports-1'
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl  => 'pltelemetry_heartbeat_acl.xml',
    host => 'example_02-weblogic-erp-1'
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl  => 'pltelemetry_heartbeat_acl.xml',
    host => 'example_02-email-service-1'
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl  => 'pltelemetry_heartbeat_acl.xml',
    host => 'example_02-batch-processor-1'
  );
  
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl  => 'pltelemetry_heartbeat_acl.xml',
    host => 'example_02-document-service-1'
  );
  
  -- Also add the OTLP collector
  DBMS_NETWORK_ACL_ADMIN.ASSIGN_ACL(
    acl  => 'pltelemetry_heartbeat_acl.xml',
    host => 'plt-otel-collector'
  );
  
  COMMIT;
END;
/