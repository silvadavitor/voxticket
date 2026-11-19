using Dapper;
using Npgsql;
using RequestService.Configuration;

namespace RequestService.Persistence;

/// <summary>Pool de conexões do Postgres do serviço. Fica "pronto" depois das migrations.</summary>
public sealed class Database
{
    readonly TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    NpgsqlDataSource? _dataSource;

    static Database() => DefaultTypeMap.MatchNamesWithUnderscores = true; // tenant_id ⇒ TenantId

    public Task Ready => _ready.Task;

    public void Configure(DatabaseCredentials credentials)
    {
        var connectionString = new NpgsqlConnectionStringBuilder
        {
            Host = EnvironmentVariables.Required("DB_HOST"),
            Port = EnvironmentVariables.Integer("DB_PORT", 5432),
            Username = credentials.Username,
            Password = credentials.Password,
            Database = credentials.DatabaseName,
            Timeout = 5,
        }.ConnectionString;
        _dataSource = NpgsqlDataSource.Create(connectionString);
    }

    public void MarkReady() => _ready.TrySetResult();

    public ValueTask<NpgsqlConnection> OpenConnectionAsync(CancellationToken ct = default) =>
        (_dataSource ?? throw new NpgsqlException("banco ainda não configurado")).OpenConnectionAsync(ct);

    public async Task<T> InTransactionAsync<T>(Func<NpgsqlConnection, NpgsqlTransaction, Task<T>> work, CancellationToken ct = default)
    {
        await using var connection = await OpenConnectionAsync(ct);
        await using var transaction = await connection.BeginTransactionAsync(ct);
        var result = await work(connection, transaction);
        await transaction.CommitAsync(ct);
        return result;
    }

    public async Task<bool> IsHealthyAsync()
    {
        if (!Ready.IsCompleted) return false;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await using var connection = await OpenConnectionAsync(timeout.Token);
            await connection.ExecuteAsync("SELECT 1");
            return true;
        }
        catch
        {
            return false;
        }
    }
}
