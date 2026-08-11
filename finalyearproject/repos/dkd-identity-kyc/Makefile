.PHONY: run build test itest lint

run:
	dotnet run --project IdentitySvc.csproj

build:
	dotnet build -c Release

lint:
	dotnet build -c Release -warnaserror

test:
	dotnet test tests/IdentitySvc.Tests/IdentitySvc.Tests.csproj -c Release --verbosity normal

itest:
	dotnet test tests/IdentitySvc.IntegrationTests/IdentitySvc.IntegrationTests.csproj \
		--filter "Category=Integration" --verbosity normal
