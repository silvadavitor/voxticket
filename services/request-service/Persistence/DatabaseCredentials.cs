using System.Text.Json.Nodes;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;
using RequestService.Configuration;
using RequestService.Infrastructure;

namespace RequestService.Persistence;

public sealed record DatabaseCredentials(string Username, string Password, string DatabaseName)
{
    /// <summary>
    /// Lê o segredo DB_SECRET_ID ({"username","password","dbname"}) no Secrets Manager, tentando de novo
    /// enquanto ele não responde. Sem DB_SECRET_ID usa DB_USER/DB_PASSWORD/DB_NAME (só para testes).
    /// </summary>
    public static async Task<DatabaseCredentials> LoadAsync(ILogger log, CancellationToken ct)
    {
        var secretId = EnvironmentVariables.Optional("DB_SECRET_ID");
        if (secretId is null)
            return new(EnvironmentVariables.Required("DB_USER"), EnvironmentVariables.Required("DB_PASSWORD"), EnvironmentVariables.Required("DB_NAME"));

        DatabaseCredentials? credentials = null;
        await Retry.ForeverAsync(async () => credentials = await ReadSecretAsync(secretId, ct),
            $"read secret {secretId}", log, ct, isRetryable: _ => true);
        return credentials!;
    }

    static async Task<DatabaseCredentials> ReadSecretAsync(string secretId, CancellationToken ct)
    {
        using var client = new AmazonSecretsManagerClient(AwsClientConfig.Create<AmazonSecretsManagerConfig>());
        var response = await client.GetSecretValueAsync(new GetSecretValueRequest { SecretId = secretId }, ct);
        var secret = JsonNode.Parse(response.SecretString)!;
        return new(secret["username"]!.GetValue<string>(), secret["password"]!.GetValue<string>(), secret["dbname"]!.GetValue<string>());
    }
}
