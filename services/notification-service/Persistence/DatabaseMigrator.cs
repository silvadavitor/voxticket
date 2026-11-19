using Dapper;
using Npgsql;
using NotificationService.Infrastructure;

namespace NotificationService.Persistence;

/// <summary>Aplica migrations/*.sql em ordem, uma vez cada, sob advisory lock (várias réplicas sobem juntas).</summary>
public sealed class DatabaseMigrator(Database database, ILogger<DatabaseMigrator> log)
{
    const long LockKey = 7201126;
    static readonly string MigrationsDirectory = Path.Combine(AppContext.BaseDirectory, "migrations");

    public Task MigrateAsync(CancellationToken ct) => Retry.ForeverAsync(async () =>
    {
        await using var connection = await database.OpenConnectionAsync(ct);
        await connection.ExecuteAsync("SELECT pg_advisory_lock(@LockKey)", new { LockKey });
        try
        {
            await connection.ExecuteAsync(
                "CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())");
            foreach (var file in Directory.GetFiles(MigrationsDirectory, "*.sql").Order())
                await ApplyAsync(connection, file, ct);
        }
        finally
        {
            await connection.ExecuteAsync("SELECT pg_advisory_unlock(@LockKey)", new { LockKey });
        }
    }, "migrations", log, ct);

    async Task ApplyAsync(NpgsqlConnection connection, string file, CancellationToken ct)
    {
        var version = Path.GetFileNameWithoutExtension(file);
        var applied = await connection.ExecuteScalarAsync<bool>("SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version=@version)", new { version });
        if (applied) return;

        await using var transaction = await connection.BeginTransactionAsync(ct);
        await connection.ExecuteAsync(await File.ReadAllTextAsync(file, ct), transaction: transaction);
        await connection.ExecuteAsync("INSERT INTO schema_migrations(version) VALUES (@version)", new { version }, transaction);
        await transaction.CommitAsync(ct);
        log.LogInformation("migration applied {version}", version);
    }
}
