CREATE TABLE dbo.Jobs (
    row_id INT NOT NULL PRIMARY KEY,
    processed BIT NOT NULL DEFAULT 0,
    payload VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    processed_at DATETIME2 NULL
);
