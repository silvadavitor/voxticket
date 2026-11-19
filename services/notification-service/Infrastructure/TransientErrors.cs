using System.Net.Sockets;
using Amazon.Runtime;
using Npgsql;
using RabbitMQ.Client.Exceptions;

namespace NotificationService.Infrastructure;

/// <summary>Banco, S3 ou rede fora: vale tentar de novo (a mensagem não vai para a DLQ).</summary>
public static class TransientErrors
{
    public static bool IsTransient(Exception exception) => exception switch
    {
        PostgresException postgres => IsConnectionFailure(postgres.SqlState),
        NpgsqlException or TimeoutException or SocketException or HttpRequestException => true,
        AmazonServiceException aws => (int)aws.StatusCode >= 500,
        AmazonClientException => true,
        BrokerUnreachableException or AlreadyClosedException or OperationInterruptedException => true,
        _ => exception.InnerException is not null && IsTransient(exception.InnerException),
    };

    // 08xxx = falha de conexão; 57Pxx = servidor reiniciando/desligando
    static bool IsConnectionFailure(string sqlState) => sqlState.StartsWith("08") || sqlState.StartsWith("57P");
}
