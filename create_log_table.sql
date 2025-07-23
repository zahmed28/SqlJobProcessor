CREATE TABLE dbo.JobProcessingLog (
    log_id INT IDENTITY PRIMARY KEY,
    row_id INT,
    error_message NVARCHAR(MAX),
    error_time DATETIME2 DEFAULT SYSDATETIME()
);
