-- PLTelemetry Error Handling Patterns
-- This file demonstrates robust error handling patterns with PLTelemetry
-- to ensure telemetry never breaks your business logic

PROMPT ================================================================================
PROMPT PLTelemetry Error Handling Patterns
PROMPT ================================================================================

-- Pattern 1: Basic error handling with span status
-- ============================================================================
PROMPT
PROMPT Pattern 1: Basic error handling with span status
PROMPT ============================================================================

CREATE OR REPLACE PROCEDURE error_handling_basic_example
IS
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    l_trace_id := PLTelemetry.start_trace('error_handling_basic');
    l_span_id := PLTelemetry.start_span('risky_operation');
    
    BEGIN
        -- Simulate business logic that might fail
        IF DBMS_RANDOM.VALUE(0, 1) > 0.5 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Simulated business error');
        END IF;
        
        -- Success path
        PLTelemetry.add_event(l_span_id, 'operation_successful');
        PLTelemetry.end_span(l_span_id, 'OK');
        
        DBMS_OUTPUT.PUT_LINE('Operation completed successfully');
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Error path - capture error details
            l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
            l_attrs(2) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            l_attrs(3) := PLTelemetry.add_attribute('error.type', 'business_error');
            
            PLTelemetry.add_event(l_span_id, 'operation_failed', l_attrs);
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            
            DBMS_OUTPUT.PUT_LINE('Operation failed: ' || SQLERRM);
            
            -- IMPORTANT: Re-raise the original exception
            -- Telemetry should never swallow business exceptions
            RAISE;
    END;
    
    PLTelemetry.end_trace(l_trace_id);
END;
/

-- Test the basic error handling
BEGIN
    FOR i IN 1..3 LOOP
        BEGIN
            error_handling_basic_example();
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('Caught exception in test: ' || SQLERRM);
        END;
    END LOOP;
END;
/

-- Pattern 2: Nested operations with proper error propagation
-- ============================================================================
PROMPT
PROMPT Pattern 2: Nested operations with proper error propagation
PROMPT ============================================================================

CREATE OR REPLACE PROCEDURE error_handling_nested_example
IS
    l_trace_id VARCHAR2(32);
    l_main_span VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
BEGIN
    l_trace_id := PLTelemetry.start_trace('error_handling_nested');
    l_main_span := PLTelemetry.start_span('main_operation');
    
    BEGIN
        -- Step 1: Validation (might fail)
        DECLARE
            l_validation_span VARCHAR2(16);
        BEGIN
            l_validation_span := PLTelemetry.start_span('validate_input', l_main_span);
            
            -- Simulate validation logic
            IF DBMS_RANDOM.VALUE(0, 1) > 0.7 THEN
                RAISE_APPLICATION_ERROR(-20100, 'Validation failed: invalid input');
            END IF;
            
            PLTelemetry.end_span(l_validation_span, 'OK');
        EXCEPTION
            WHEN OTHERS THEN
                l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
                l_attrs(2) := PLTelemetry.add_attribute('validation.step', 'input_validation');
                PLTelemetry.end_span(l_validation_span, 'ERROR', l_attrs);
                RAISE; -- Propagate to parent
        END;
        
        -- Step 2: Database operation (might fail)
        DECLARE
            l_db_span VARCHAR2(16);
        BEGIN
            l_db_span := PLTelemetry.start_span('database_operation', l_main_span);
            
            l_attrs.DELETE;
            l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_DB_OPERATION, 'INSERT');
            
            -- Simulate database operation
            IF DBMS_RANDOM.VALUE(0, 1) > 0.8 THEN
                RAISE_APPLICATION_ERROR(-20200, 'Database constraint violation');
            END IF;
            
            PLTelemetry.end_span(l_db_span, 'OK', l_attrs);
        EXCEPTION
            WHEN OTHERS THEN
                l_attrs(2) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
                l_attrs(3) := PLTelemetry.add_attribute('db.error_type', 'constraint_violation');
                PLTelemetry.end_span(l_db_span, 'ERROR', l_attrs);
                RAISE; -- Propagate to parent
        END;
        
        -- Step 3: External API call (might fail)
        DECLARE
            l_api_span VARCHAR2(16);
        BEGIN
            l_api_span := PLTelemetry.start_span('external_api_call', l_main_span);
            
            l_attrs.DELETE;
            l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_METHOD, 'POST');
            l_attrs(2) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_URL, 'https://api.example.com/notify');
            
            -- Simulate API call
            IF DBMS_RANDOM.VALUE(0, 1) > 0.9 THEN
                RAISE_APPLICATION_ERROR(-20300, 'External API timeout');
            END IF;
            
            l_attrs(3) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_STATUS, '200');
            PLTelemetry.end_span(l_api_span, 'OK', l_attrs);
        EXCEPTION
            WHEN OTHERS THEN
                l_attrs(3) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_HTTP_STATUS, '500');
                l_attrs(4) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
                PLTelemetry.end_span(l_api_span, 'ERROR', l_attrs);
                RAISE; -- Propagate to parent
        END;
        
        -- All steps successful
        PLTelemetry.add_event(l_main_span, 'all_operations_completed');
        PLTelemetry.end_span(l_main_span, 'OK');
        
        DBMS_OUTPUT.PUT_LINE('All nested operations completed successfully');
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Handle any error from nested operations
            l_attrs.DELETE;
            l_attrs(1) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
            l_attrs(2) := PLTelemetry.add_attribute('error.source', 'nested_operation');
            l_attrs(3) := PLTelemetry.add_attribute('error.code', TO_CHAR(SQLCODE));
            
            PLTelemetry.add_event(l_main_span, 'nested_operation_failed', l_attrs);
            PLTelemetry.end_span(l_main_span, 'ERROR', l_attrs);
            
            DBMS_OUTPUT.PUT_LINE('Nested operation failed: ' || SQLERRM);
            RAISE;
    END;
    
    PLTelemetry.end_trace(l_trace_id);
END;
/

-- Test nested error handling
BEGIN
    FOR i IN 1..5 LOOP
        BEGIN
            error_handling_nested_example();
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('Test ' || i || ' - Caught: ' || SQLERRM);
        END;
    END LOOP;
END;
/

-- Pattern 3: Telemetry-safe operations (never fail business logic)
-- ============================================================================
PROMPT
PROMPT Pattern 3: Telemetry-safe operations (defensive programming)
PROMPT ============================================================================

CREATE OR REPLACE PROCEDURE telemetry_safe_operation_example
IS
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
    l_result   NUMBER;
BEGIN
    -- Business logic that must succeed regardless of telemetry issues
    l_result := calculate_important_value();
    
    -- Telemetry operations wrapped in defensive blocks
    BEGIN
        l_trace_id := PLTelemetry.start_trace('safe_operation');
    EXCEPTION
        WHEN OTHERS THEN
            -- Telemetry failed to start, but business continues
            DBMS_OUTPUT.PUT_LINE('Warning: Failed to start trace, continuing without telemetry');
            l_trace_id := NULL;
    END;
    
    BEGIN
        IF l_trace_id IS NOT NULL THEN
            l_span_id := PLTelemetry.start_span('calculate_value');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Warning: Failed to start span');
            l_span_id := NULL;
    END;
    
    -- Add telemetry events safely
    BEGIN
        IF l_span_id IS NOT NULL THEN
            l_attrs(1) := PLTelemetry.add_attribute('calculation.result', TO_CHAR(l_result));
            PLTelemetry.add_event(l_span_id, 'calculation_completed', l_attrs);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Warning: Failed to add telemetry event');
    END;
    
    -- End telemetry safely
    BEGIN
        IF l_span_id IS NOT NULL THEN
            PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Warning: Failed to end span');
    END;
    
    BEGIN
        IF l_trace_id IS NOT NULL THEN
            PLTelemetry.end_trace(l_trace_id);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Warning: Failed to end trace');
    END;
    
    -- Business logic completes successfully regardless of telemetry
    DBMS_OUTPUT.PUT_LINE('Business operation completed with result: ' || l_result);
END;

-- Helper function for the example
CREATE OR REPLACE FUNCTION calculate_important_value RETURN NUMBER
IS
BEGIN
    -- Critical business calculation that must never fail
    RETURN ROUND(DBMS_RANDOM.VALUE(1, 1000), 2);
END;
/

-- Test telemetry-safe operations
BEGIN
    telemetry_safe_operation_example();
END;
/

-- Pattern 4: Transaction rollback with telemetry preservation
-- ============================================================================
PROMPT
PROMPT Pattern 4: Transaction rollback with telemetry preservation
PROMPT ============================================================================

CREATE OR REPLACE PROCEDURE transaction_rollback_example
IS
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
    l_savepoint_name VARCHAR2(30) := 'BEFORE_BUSINESS_LOGIC';
BEGIN
    l_trace_id := PLTelemetry.start_trace('transaction_with_rollback');
    l_span_id := PLTelemetry.start_span('transactional_operation');
    
    -- Set savepoint before business transaction
    SAVEPOINT before_business_logic;
    
    BEGIN
        -- Simulate transactional business logic
        l_attrs(1) := PLTelemetry.add_attribute('transaction.type', 'financial');
        PLTelemetry.add_event(l_span_id, 'transaction_started', l_attrs);
        
        -- Business operations that might need rollback
        INSERT INTO test_table VALUES (1, 'test_data', SYSDATE);
        
        -- Simulate error condition
        IF DBMS_RANDOM.VALUE(0, 1) > 0.5 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Business rule violation - transaction must be rolled back');
        END IF;
        
        -- Success path
        PLTelemetry.add_event(l_span_id, 'transaction_committed');
        PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
        
        -- Commit business transaction (telemetry auto-commits separately if needed)
        COMMIT;
        
        DBMS_OUTPUT.PUT_LINE('Transaction completed successfully');
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Rollback business transaction to savepoint
            ROLLBACK TO before_business_logic;
            
            -- Add error information to telemetry
            l_attrs(2) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
            l_attrs(3) := PLTelemetry.add_attribute('transaction.status', 'rolled_back');
            
            PLTelemetry.add_event(l_span_id, 'transaction_rolled_back', l_attrs);
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            
            -- Telemetry is preserved (it commits separately in async mode)
            
            DBMS_OUTPUT.PUT_LINE('Transaction rolled back: ' || SQLERRM);
            -- Don't re-raise if this is expected business behavior
    END;
    
    PLTelemetry.end_trace(l_trace_id);
END;
/

-- Create test table for the example
CREATE TABLE test_table (
    id NUMBER PRIMARY KEY,
    data VARCHAR2(100),
    created_date DATE
);

-- Test transaction rollback
BEGIN
    FOR i IN 1..3 LOOP
        DBMS_OUTPUT.PUT_LINE('--- Test ' || i || ' ---');
        transaction_rollback_example();
    END LOOP;
END;
/

-- Clean up test table
DROP TABLE test_table;

-- Pattern 5: Retry logic with telemetry
-- ============================================================================
PROMPT
PROMPT Pattern 5: Retry logic with telemetry tracking
PROMPT ============================================================================

CREATE OR REPLACE PROCEDURE retry_logic_example
IS
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_retry_span VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
    l_max_retries CONSTANT NUMBER := 3;
    l_retry_count NUMBER := 0;
    l_success BOOLEAN := FALSE;
BEGIN
    l_trace_id := PLTelemetry.start_trace('operation_with_retries');
    l_span_id := PLTelemetry.start_span('retry_operation');
    
    l_attrs(1) := PLTelemetry.add_attribute('retry.max_attempts', TO_CHAR(l_max_retries));
    PLTelemetry.add_event(l_span_id, 'retry_operation_started', l_attrs);
    
    WHILE l_retry_count < l_max_retries AND NOT l_success LOOP
        l_retry_count := l_retry_count + 1;
        
        -- Create span for each retry attempt
        l_retry_span := PLTelemetry.start_span('retry_attempt_' || l_retry_count, l_span_id);
        
        l_attrs.DELETE;
        l_attrs(1) := PLTelemetry.add_attribute('retry.attempt', TO_CHAR(l_retry_count));
        l_attrs(2) := PLTelemetry.add_attribute('retry.max_attempts', TO_CHAR(l_max_retries));
        
        BEGIN
            PLTelemetry.add_event(l_retry_span, 'attempt_started', l_attrs);
            
            -- Simulate operation that might fail
            IF DBMS_RANDOM.VALUE(0, 1) > (0.3 * l_retry_count) THEN  -- Higher success chance each retry
                RAISE_APPLICATION_ERROR(-20001, 'Temporary failure - attempt ' || l_retry_count);
            END IF;
            
            -- Success!
            l_success := TRUE;
            PLTelemetry.add_event(l_retry_span, 'attempt_successful', l_attrs);
            PLTelemetry.end_span(l_retry_span, 'OK', l_attrs);
            
            DBMS_OUTPUT.PUT_LINE('Operation succeeded on attempt ' || l_retry_count);
            
        EXCEPTION
            WHEN OTHERS THEN
                l_attrs(3) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
                l_attrs(4) := PLTelemetry.add_attribute('retry.will_retry', 
                    CASE WHEN l_retry_count < l_max_retries THEN 'true' ELSE 'false' END);
                
                PLTelemetry.add_event(l_retry_span, 'attempt_failed', l_attrs);
                PLTelemetry.end_span(l_retry_span, 'ERROR', l_attrs);
                
                DBMS_OUTPUT.PUT_LINE('Attempt ' || l_retry_count || ' failed: ' || SQLERRM);
                
                -- If not the last attempt, wait before retrying
                IF l_retry_count < l_max_retries THEN
                    DBMS_LOCK.SLEEP(l_retry_count);  -- Exponential backoff
                ELSE
                    -- All retries exhausted
                    l_attrs(5) := PLTelemetry.add_attribute('retry.exhausted', 'true');
                    PLTelemetry.add_event(l_span_id, 'all_retries_exhausted', l_attrs);
                    PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
                    PLTelemetry.end_trace(l_trace_id);
                    RAISE_APPLICATION_ERROR(-20999, 'Operation failed after ' || l_max_retries || ' attempts');
                END IF;
        END;
    END LOOP;
    
    -- Operation succeeded
    l_attrs.DELETE;
    l_attrs(1) := PLTelemetry.add_attribute('retry.final_attempt', TO_CHAR(l_retry_count));
    l_attrs(2) := PLTelemetry.add_attribute('retry.success', 'true');
    
    PLTelemetry.add_event(l_span_id, 'retry_operation_completed', l_attrs);
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    PLTelemetry.end_trace(l_trace_id);
END;
/

-- Test retry logic
BEGIN
    FOR i IN 1..3 LOOP
        BEGIN
            DBMS_OUTPUT.PUT_LINE('=== Retry Test ' || i || ' ===');
            retry_logic_example();
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('Final failure: ' || SQLERRM);
        END;
        DBMS_OUTPUT.PUT_LINE('');
    END LOOP;
END;
/

-- Pattern 6: Circuit breaker pattern with telemetry
-- ============================================================================
PROMPT
PROMPT Pattern 6: Circuit breaker pattern with telemetry
PROMPT ============================================================================

-- Simple circuit breaker state table
CREATE TABLE circuit_breaker_state (
    service_name VARCHAR2(100) PRIMARY KEY,
    state VARCHAR2(20) CHECK (state IN ('CLOSED', 'OPEN', 'HALF_OPEN')),
    failure_count NUMBER DEFAULT 0,
    last_failure TIMESTAMP,
    next_attempt TIMESTAMP
);

CREATE OR REPLACE PROCEDURE circuit_breaker_example(
    p_service_name VARCHAR2 DEFAULT 'external_api'
)
IS
    l_trace_id VARCHAR2(32);
    l_span_id  VARCHAR2(16);
    l_attrs    PLTelemetry.t_attributes;
    l_state    VARCHAR2(20);
    l_failure_count NUMBER;
    l_next_attempt TIMESTAMP;
    l_max_failures CONSTANT NUMBER := 3;
    l_timeout_minutes CONSTANT NUMBER := 5;
BEGIN
    l_trace_id := PLTelemetry.start_trace('circuit_breaker_operation');
    l_span_id := PLTelemetry.start_span('check_circuit_breaker');
    
    l_attrs(1) := PLTelemetry.add_attribute('service.name', p_service_name);
    l_attrs(2) := PLTelemetry.add_attribute('circuit_breaker.max_failures', TO_CHAR(l_max_failures));
    
    -- Get current circuit breaker state
    BEGIN
        SELECT state, failure_count, next_attempt
        INTO l_state, l_failure_count, l_next_attempt
        FROM circuit_breaker_state
        WHERE service_name = p_service_name;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- Initialize circuit breaker
            INSERT INTO circuit_breaker_state (service_name, state, failure_count)
            VALUES (p_service_name, 'CLOSED', 0);
            l_state := 'CLOSED';
            l_failure_count := 0;
    END;
    
    l_attrs(3) := PLTelemetry.add_attribute('circuit_breaker.state', l_state);
    l_attrs(4) := PLTelemetry.add_attribute('circuit_breaker.failure_count', TO_CHAR(l_failure_count));
    
    -- Check if circuit breaker allows the call
    IF l_state = 'OPEN' THEN
        IF SYSTIMESTAMP < l_next_attempt THEN
            -- Circuit is open and timeout not reached
            l_attrs(5) := PLTelemetry.add_attribute('circuit_breaker.action', 'blocked');
            PLTelemetry.add_event(l_span_id, 'circuit_breaker_blocked_call', l_attrs);
            PLTelemetry.end_span(l_span_id, 'ERROR', l_attrs);
            PLTelemetry.end_trace(l_trace_id);
            
            RAISE_APPLICATION_ERROR(-20503, 'Service unavailable - circuit breaker is OPEN');
        ELSE
            -- Timeout reached, transition to HALF_OPEN
            UPDATE circuit_breaker_state 
            SET state = 'HALF_OPEN' 
            WHERE service_name = p_service_name;
            l_state := 'HALF_OPEN';
            
            l_attrs(5) := PLTelemetry.add_attribute('circuit_breaker.action', 'half_open_transition');
            PLTelemetry.add_event(l_span_id, 'circuit_breaker_half_open', l_attrs);
        END IF;
    END IF;
    
    PLTelemetry.end_span(l_span_id, 'OK', l_attrs);
    
    -- Attempt the actual service call
    DECLARE
        l_call_span VARCHAR2(16);
    BEGIN
        l_call_span := PLTelemetry.start_span('service_call', l_span_id);
        
        l_attrs(5) := PLTelemetry.add_attribute('circuit_breaker.call_allowed', 'true');
        PLTelemetry.add_event(l_call_span, 'service_call_started', l_attrs);
        
        -- Simulate service call that might fail
        IF DBMS_RANDOM.VALUE(0, 1) > 0.7 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Service call failed');
        END IF;
        
        -- Success - reset circuit breaker
        IF l_state IN ('HALF_OPEN', 'CLOSED') THEN
            UPDATE circuit_breaker_state 
            SET state = 'CLOSED', failure_count = 0, last_failure = NULL, next_attempt = NULL
            WHERE service_name = p_service_name;
            
            l_attrs(6) := PLTelemetry.add_attribute('circuit_breaker.reset', 'true');
        END IF;
        
        PLTelemetry.add_event(l_call_span, 'service_call_successful', l_attrs);
        PLTelemetry.end_span(l_call_span, 'OK', l_attrs);
        
        DBMS_OUTPUT.PUT_LINE('Service call successful - circuit breaker reset to CLOSED');
        
    EXCEPTION
        WHEN OTHERS THEN
            -- Service call failed
            l_failure_count := l_failure_count + 1;
            
            l_attrs(6) := PLTelemetry.add_attribute(PLTelemetry.C_ATTR_ERROR_MESSAGE, SQLERRM);
            l_attrs(7) := PLTelemetry.add_attribute('circuit_breaker.failure_count', TO_CHAR(l_failure_count));
            
            IF l_failure_count >= l_max_failures THEN
                -- Open the circuit breaker
                UPDATE circuit_breaker_state 
                SET state = 'OPEN', 
                    failure_count = l_failure_count,
                    last_failure = SYSTIMESTAMP,
                    next_attempt = SYSTIMESTAMP + INTERVAL l_timeout_minutes MINUTE
                WHERE service_name = p_service_name;
                
                l_attrs(8) := PLTelemetry.add_attribute('circuit_breaker.opened', 'true');
                l_attrs(9) := PLTelemetry.add_attribute('circuit_breaker.timeout_minutes', TO_CHAR(l_timeout_minutes));
                PLTelemetry.add_event(l_call_span, 'circuit_breaker_opened', l_attrs);
                
                DBMS_OUTPUT.PUT_LINE('Circuit breaker OPENED due to ' || l_failure_count || ' failures');
            ELSE
                -- Increment failure count but keep circuit closed
                UPDATE circuit_breaker_state 
                SET failure_count = l_failure_count, last_failure = SYSTIMESTAMP
                WHERE service_name = p_service_name;
                
                PLTelemetry.add_event(l_call_span, 'service_call_failed', l_attrs);
                DBMS_OUTPUT.PUT_LINE('Service call failed (' || l_failure_count || '/' || l_max_failures || ' failures)');
            END IF;
            
            PLTelemetry.end_span(l_call_span, 'ERROR', l_attrs);
            PLTelemetry.end_trace(l_trace_id);
            RAISE;
    END;
    
    PLTelemetry.end_trace(l_trace_id);
END;
/

-- Test circuit breaker pattern
BEGIN
    FOR i IN 1..8 LOOP
        BEGIN
            DBMS_OUTPUT.PUT_LINE('=== Circuit Breaker Test ' || i || ' ===');
            circuit_breaker_example('test_service');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('Call blocked/failed: ' || SQLERRM);
        END;
        DBMS_OUTPUT.PUT_LINE('');
        
        -- Brief pause between calls
        DBMS_LOCK.SLEEP(1);
    END LOOP;
END;
/

-- Clean up circuit breaker test
DROP TABLE circuit_breaker_state;

PROMPT
PROMPT ================================================================================
PROMPT Error Handling Patterns Summary
PROMPT ================================================================================
PROMPT
PROMPT Patterns Demonstrated:
PROMPT ✓ Basic error handling with span status tracking
PROMPT ✓ Nested operations with proper error propagation
PROMPT ✓ Telemetry-safe operations (defensive programming)
PROMPT ✓ Transaction rollback with telemetry preservation
PROMPT ✓ Retry logic with attempt tracking
PROMPT ✓ Circuit breaker pattern with state management
PROMPT
PROMPT Key Principles:
PROMPT 1. NEVER let telemetry break business logic
PROMPT 2. Always re-raise business exceptions after telemetry
PROMPT 3. Use defensive programming for telemetry operations
PROMPT 4. Preserve telemetry data even during transaction rollbacks
PROMPT 5. Track retry attempts and failure patterns
PROMPT 6. Implement circuit breakers for external dependencies
PROMPT 7. Use proper error attributes for debugging
PROMPT
PROMPT Best Practices:
PROMPT • Wrap telemetry calls in BEGIN/EXCEPTION blocks
PROMPT • Use savepoints to preserve telemetry during rollbacks
PROMPT • Add comprehensive error attributes for debugging
PROMPT • Track patterns like retries and circuit breaker states
PROMPT • Set proper span status (OK/ERROR) for observability
PROMPT • Log both technical and business error contexts
PROMPT
PROMPT ================================================================================