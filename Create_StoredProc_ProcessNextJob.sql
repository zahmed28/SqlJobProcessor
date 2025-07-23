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
