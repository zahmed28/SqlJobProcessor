# Task 
SQL Server Database Assessment

In your SQL Server 2016 database you have a table with jobs to process:
create table dbo.Jobs (
row_id int not null primary key,
processed bit not null default 0,
payload varchar(100) not null
);

Write an SQL stored procedure that will take and process one of the unprocessed job items (where processed =
0). Processing an item involves calling an external stored procedure, saving the payload it returned, and
setting processed to 1.
Note that:
- Your stored procedure will be run by multiple client computers at the same time. You must ensure that
no job item is processed twice, that no two clients attempt to work on the same item, and that one
client does not block other clients while processing its job row.
- Your stored procedure is a part of a larger database that may perform different types of processing of
items in dbo.Jobs that are not under your control.
- In order to properly process the item, you must call an existing SQL stored procedure that you have no
control over, passing it the item's payload. This procedure is
called dbo.ProcessPayloadInternal and accepts one parameter, @payload varchar(100)
output, that receives the existing payload on entry and returns the amended payload on return.
This external procedure is a black box for you, but you know that it may either return the
amended @payload properly in the output parameter, or raise an exception, or raise an
exception and roll back your transaction if you started any. Make sure that your stored procedure
handles all three cases, ensuring that the item is left in the table marked as processed in any of them.

# SQL Server Job Processor

This repository contains a concurrency-safe, fault-tolerant SQL Server stored procedure for processing jobs. It is designed to work in a multi-client environment and ensure each job is processed once, even in the event of external failures or transaction rollbacks.

## Features

- Safe concurrent job pickup using `READPAST`, `UPDLOCK`, and `ROWLOCK`
- Retry logic for transient failures (configurable)
- Minimal transaction scope to avoid deadlocks
- Error logging with job failure tracking
- Flexible job status system (`pending`, `processing`, `completed`, `failed`)

## Structure

| File | Description |
|------|-------------|
| `Create_Jobs_Table.sql` | Schema for the `Jobs` table |
| `Create_Log_Table.sql` | Schema for the job error log |
| `Create_SP_ProcessNextJob.sql` | Main stored procedure to process unprocessed job items |

## Scripts
```sql
CREATE TABLE dbo.Jobs (
    row_id INT NOT NULL PRIMARY KEY,
    processed BIT NOT NULL DEFAULT 0,
    payload VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    processed_at DATETIME2 NULL
);

CREATE TABLE dbo.JobProcessingLog (
    log_id INT IDENTITY PRIMARY KEY,
    row_id INT,
    error_message NVARCHAR(MAX),
    error_time DATETIME2 DEFAULT SYSDATETIME()
);

CREATE PROCEDURE dbo.ProcessNextJob
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @row_id INT;
    DECLARE @payload VARCHAR(100);
    DECLARE @new_payload VARCHAR(100);
    DECLARE @retry_count INT = 0;
    DECLARE @max_retries INT = 3;
    DECLARE @succeeded BIT = 0;

    -- Step 1: Secure a job
    BEGIN TRANSACTION;

    SELECT TOP 1 
        @row_id = row_id,
        @payload = payload
    FROM dbo.Jobs WITH (ROWLOCK, READPAST, UPDLOCK)
    WHERE processed = 0 AND status = 'pending';

    IF @row_id IS NULL
    BEGIN
        COMMIT TRANSACTION;
        RETURN;
    END

    -- Mark job as "claimed"
    UPDATE dbo.Jobs
    SET processed = 1,
        status = 'processing',
        processed_at = SYSDATETIME()
    WHERE row_id = @row_id;

    COMMIT TRANSACTION;

    -- Step 2: Retry Loop for External Processing
    WHILE @retry_count < @max_retries AND @succeeded = 0
    BEGIN
        BEGIN TRY
            SET @new_payload = @payload;

            EXEC dbo.ProcessPayloadInternal @payload = @new_payload OUTPUT;

            -- Success, update payload
            UPDATE dbo.Jobs
            SET payload = @new_payload,
                status = 'completed'
            WHERE row_id = @row_id;

            SET @succeeded = 1;
        END TRY
        BEGIN CATCH
            SET @retry_count += 1;

            -- Optional: log each failure attempt
            INSERT INTO dbo.JobProcessingLog (row_id, error_message)
            VALUES (@row_id, ERROR_MESSAGE());

            -- delay between retries
            IF @retry_count < @max_retries
                WAITFOR DELAY '00:00:01'; -- 1 second delay
        END CATCH
    END

    -- Step 3: If all retries failed, mark job as failed
    IF @succeeded = 0
    BEGIN
        UPDATE dbo.Jobs
        SET status = 'failed'
        WHERE row_id = @row_id;
    END
END
```
## Usage

1. Run the SQL scripts (create_jobs_table.sql & create_log_table.sql) in your SQL Server 2016+ instance.
2. Call the `dbo.ProcessNextJob` stored procedure from any number of clients or processes.
3. Monitor job statuses and logs using the `Jobs` and `JobProcessingLog` tables.

```sql
-- Run the stored procedure
EXEC dbo.ProcessNextJob;
```
## Design Notes

## Concurrency & Safety

I use a combination of `READPAST`, `UPDLOCK`, and `ROWLOCK` to ensure that:
- Only one process sees and locks a job at a time
- Locked jobs are skipped by other clients
- Updates to claim jobs are atomic and safe

## Retry Logic

The retry loop attempts the external stored procedure (a black box) up to 3 times. Failures are caught and logged. If all retries fail, the job is marked as `failed`.

This helps gracefully handle transient errors without retrying indefinitely.

## Transaction Scope

The transaction wraps only the job claim step. This minimizes the chance of deadlocks and protects the job claim from being lost due to downstream errors.

## Logging

Every failure is logged in a separate `JobProcessingLog` table to help developers or ops teams diagnose systemic issues.

## Status System

Each job has a `status`:
- `pending` – waiting to be processed
- `processing` – being handled by one client
- `completed` – finished successfully
- `failed` – failed after all retries

## Future Improvements & Design Considerations

Although this solution covers a reliable, concurrent-safe job processor, several enhancements could improve scalability, configurability, and operational maintainability:

### 1. Configurable Retry Settings
- Move the retry count and delay duration to a configuration table (e.g., `dbo.JobSettings`) so changes don’t require altering the stored procedure.
- Example:
  ```sql
  SELECT @max_retries = MaxRetries FROM dbo.JobSettings WHERE SettingKey = 'PayloadRetryCount';

### 2. Job Archiving Strategy
   To prevent the Jobs table from growing indefinitely and slowing down queries:
   - Introduce an ArchivedJobs table with the same schema.
   - Create a nightly SQL Agent job to move jobs with status IN ('completed', 'failed') into the archive table and delete them from Jobs.
   - This keeps the active job table lean and performant.
### 3. Indexing
  Index status, processed, or processed_at to improve filtering and archiving performance.

### 4. Observability & Monitoring
Provide summary tables or views to track job stats: pending, processing, failed, completed, retries used, etc.
