using System.Net;
using Amazon.S3;
using Amazon.S3.Model;
using RequestService.Configuration;
using RequestService.Infrastructure;

namespace RequestService.Storage;

/// <summary>Áudios no S3: audios/{tenant}/{requestId}.ext; na compensação vão para failed/.</summary>
public sealed class AudioStorage
{
    const string AudiosPrefix = "audios/";
    const string FailedPrefix = "failed/";
    readonly string _bucket = EnvironmentVariables.Required("S3_BUCKET");
    readonly AmazonS3Client _s3;

    public AudioStorage()
    {
        var config = AwsClientConfig.Create<AmazonS3Config>();
        config.ForcePathStyle = AwsClientConfig.UsesLocalEmulator;
        _s3 = new AmazonS3Client(config);
    }

    public static string KeyFor(string tenantId, Guid requestId, string fileName) =>
        $"{AudiosPrefix}{tenantId}/{requestId}{Path.GetExtension(fileName).ToLowerInvariant()}";

    public Task UploadAsync(string key, Stream content, string contentType, CancellationToken ct) =>
        _s3.PutObjectAsync(new PutObjectRequest
        {
            BucketName = _bucket,
            Key = key,
            InputStream = content,
            ContentType = contentType,
            AutoCloseStream = false,
        }, ct);

    /// <summary>Copia para failed/ e apaga o original. Idempotente: se já foi movido, não faz nada.</summary>
    public async Task MoveToFailedAsync(string key, CancellationToken ct)
    {
        var destination = FailedPrefix + (key.StartsWith(AudiosPrefix) ? key[AudiosPrefix.Length..] : key);
        try
        {
            await _s3.CopyObjectAsync(new CopyObjectRequest
            {
                SourceBucket = _bucket,
                SourceKey = key,
                DestinationBucket = _bucket,
                DestinationKey = destination,
            }, ct);
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return;
        }
        await _s3.DeleteObjectAsync(_bucket, key, ct);
    }
}
