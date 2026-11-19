using Amazon;
using Amazon.Runtime;
using RequestService.Configuration;

namespace RequestService.Infrastructure;

public static class AwsClientConfig
{
    /// <summary>Com AWS_ENDPOINT_URL fala com o MiniStack; sem ele, com a AWS real.</summary>
    public static T Create<T>() where T : ClientConfig, new()
    {
        var region = EnvironmentVariables.Optional("AWS_REGION") ?? "us-east-1";
        var config = new T
        {
            RegionEndpoint = RegionEndpoint.GetBySystemName(region),
            RequestChecksumCalculation = RequestChecksumCalculation.WHEN_REQUIRED,
            ResponseChecksumValidation = ResponseChecksumValidation.WHEN_REQUIRED,
        };
        if (EnvironmentVariables.Optional("AWS_ENDPOINT_URL") is { } endpoint)
        {
            config.ServiceURL = endpoint;
            config.AuthenticationRegion = region;
        }
        return config;
    }

    public static bool UsesLocalEmulator => EnvironmentVariables.Optional("AWS_ENDPOINT_URL") is not null;
}
