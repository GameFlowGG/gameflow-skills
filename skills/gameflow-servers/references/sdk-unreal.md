# Unreal Engine SDK (plugin)

GameFlow plugin for UE 5.3+ (beta, 0.1.0):
- **Modules:** `GameFlowCore` (C++ core) and `GameFlowUnreal`, which provides `UGameFlowSubsystem`, a `UGameInstanceSubsystem`.
- **Source:** `GameFlowGG/gameflow-gameserver-sdk`, folder `sdk/unreal/GameFlow`, tag `sdk/unreal/v0.1.0`. The GitHub release attaches `gameflow-unreal-sdk-0.1.0.zip`.
- There is no Marketplace/Fab listing.

## Install

```bash
git clone --depth 1 --branch sdk/unreal/v0.1.0 https://github.com/GameFlowGG/gameflow-gameserver-sdk.git /tmp/gf-sdk
cp -r /tmp/gf-sdk/sdk/unreal/GameFlow ./Plugins/GameFlow
```

1. Enable it in `.uproject`: `"Plugins": [{ "Name": "GameFlow", "Enabled": true }]`.
2. Add `"GameFlowUnreal"` to `PublicDependencyModuleNames` in your module's `.Build.cs`. Add `"Json"` too if you parse the payload as below.
3. Regenerate project files and build.

## API (real names, `UGameFlowSubsystem`)

All completion delegates fire on the game thread.

| Method / member | Notes |
|---|---|
| `Start(FGfVoidResult)` | Connects with retries, or local mode |
| `Ready(FGfVoidResult)` | Health heartbeat starts automatically |
| `Shutdown(FGfVoidResult)` | Idempotent. `Deinitialize()` also calls it when the GameInstance is torn down. |
| `ConnectPlayer(SessionId, FGfVoidResult)` | Errors: `SERVER_FULL`, `PLAYER_ALREADY_CONNECTED` |
| `DisconnectPlayer(SessionId, FGfRemoveResult)` | The delegate takes `(const FGameFlowError&, bool bFound, const FPlayerList&)`. Some README snippets show two params; that's wrong. |
| `GetPayload(FGfPayloadResult)` | `(const FGameFlowError&, const FString& Payload, bool bPresent)` |
| `GetInfo(FGfInfoResult)` | `FServerInfo` |
| `OnPayloadChanged` | Dynamic multicast `(const FString& Payload, bool bPresent)`; bind a `UFUNCTION` |
| `OnServerInfo`, `OnHealthDegraded` | Dynamic multicast events |
| `PlayerCount()`, `PlayerSessionIds()`, `PlayerCapacity()`, `PlayersTracked()`, `GetMode()` | BlueprintPure reads |
| `UGameFlowEnvLibrary::DefaultPort(int32&)`, `Port(Name, int32&)`, `Region()`, `BuildId()` | Return `false` / empty when absent |

`FGameFlowError`: `IsOk()`, `Code` (`EGameFlowErrorCode::PlayerAlreadyConnected`, `ServerFull`, …), `Message`.

## Minimal lifecycle (GameMode)

```cpp
// MyServerGameMode.h
#pragma once
#include "CoreMinimal.h"
#include "GameFramework/GameModeBase.h"
#include "GameFlowSubsystem.h"
#include "MyServerGameMode.generated.h"

UCLASS()
class AMyServerGameMode : public AGameModeBase
{
    GENERATED_BODY()
public:
    virtual void BeginPlay() override;
    virtual void PreLogin(const FString& Options, const FString& Address, const FUniqueNetIdRepl& UniqueId, FString& ErrorMessage) override;
    virtual FString InitNewPlayer(APlayerController* NewPlayerController, const FUniqueNetIdRepl& UniqueId, const FString& Options, const FString& Portal = TEXT("")) override;
    virtual void PostLogin(APlayerController* NewPlayer) override;
    virtual void Logout(AController* Exiting) override;
    void EndMatchAndShutdown();
private:
    UFUNCTION() void HandlePayloadChanged(const FString& Payload, bool bPresent);
    void ApplyPayload(const FString& Payload);
    UGameFlowSubsystem* GF() const { return GetGameInstance()->GetSubsystem<UGameFlowSubsystem>(); }
    TSet<FString> ExpectedPlayers;                          // from the payload
    TMap<TWeakObjectPtr<APlayerController>, FString> PlayerIds;
};
```

```cpp
// MyServerGameMode.cpp
#include "MyServerGameMode.h"
#include "Kismet/GameplayStatics.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonReader.h"
#include "Serialization/JsonSerializer.h"

void AMyServerGameMode::BeginPlay()
{
    Super::BeginPlay();
    if (GetNetMode() != NM_DedicatedServer) return;
    UGameFlowSubsystem* Sub = GF();
    Sub->OnPayloadChanged.AddDynamic(this, &AMyServerGameMode::HandlePayloadChanged);
    Sub->Start(FGfVoidResult::CreateWeakLambda(this, [this, Sub](const FGameFlowError& Err)
    {
        if (!Err.IsOk()) { UE_LOG(LogTemp, Error, TEXT("[gameflow] Start: %s"), *Err.Message); return; }
        Sub->GetPayload(FGfPayloadResult::CreateWeakLambda(this, [this](const FGameFlowError& E, const FString& P, bool bPresent)
        {
            if (E.IsOk() && bPresent) ApplyPayload(P);
        }));
        // The net driver is already listening on -port=… by BeginPlay, so mark ready now.
        Sub->Ready(FGfVoidResult::CreateLambda([](const FGameFlowError& R)
        {
            if (!R.IsOk()) UE_LOG(LogTemp, Error, TEXT("[gameflow] Ready: %s"), *R.Message);
        }));
    }));
}

void AMyServerGameMode::HandlePayloadChanged(const FString& Payload, bool bPresent)
{
    if (bPresent) ApplyPayload(Payload); else ExpectedPlayers.Reset();
}

void AMyServerGameMode::ApplyPayload(const FString& Payload)
{
    ExpectedPlayers.Reset();
    TSharedPtr<FJsonObject> Root;
    if (!FJsonSerializer::Deserialize(TJsonReaderFactory<>::Create(Payload), Root) || !Root.IsValid()) return;
    const TArray<TSharedPtr<FJsonValue>>* Teams;
    if (!Root->TryGetArrayField(TEXT("teams"), Teams)) return;
    for (const TSharedPtr<FJsonValue>& Team : *Teams)
    {
        const TArray<TSharedPtr<FJsonValue>>* Players;
        if (Team->AsObject()->TryGetArrayField(TEXT("players"), Players))
            for (const TSharedPtr<FJsonValue>& P : *Players)
                ExpectedPlayers.Add(P->AsObject()->GetStringField(TEXT("player_id")));
    }
}

void AMyServerGameMode::PreLogin(const FString& Options, const FString& Address, const FUniqueNetIdRepl& UniqueId, FString& ErrorMessage)
{
    Super::PreLogin(Options, Address, UniqueId, ErrorMessage);
    // Client travels to host:port?PlayerId=…&Token=… ; verify Token against your backend in real code.
    const FString PlayerId = UGameplayStatics::ParseOption(Options, TEXT("PlayerId"));
    if (!ExpectedPlayers.Contains(PlayerId)) ErrorMessage = TEXT("not in this match");
}

FString AMyServerGameMode::InitNewPlayer(APlayerController* NewPlayerController, const FUniqueNetIdRepl& UniqueId, const FString& Options, const FString& Portal)
{
    // Options is this player's login URL options (already checked in PreLogin).
    PlayerIds.Add(NewPlayerController, UGameplayStatics::ParseOption(Options, TEXT("PlayerId")));
    return Super::InitNewPlayer(NewPlayerController, UniqueId, Options, Portal);
}

void AMyServerGameMode::PostLogin(APlayerController* NewPlayer)
{
    Super::PostLogin(NewPlayer);
    const FString Id = PlayerIds.FindRef(NewPlayer);
    if (Id.IsEmpty()) return;
    GF()->ConnectPlayer(Id, FGfVoidResult::CreateLambda([Id](const FGameFlowError& Err)
    {
        if (!Err.IsOk() && Err.Code != EGameFlowErrorCode::PlayerAlreadyConnected)
            UE_LOG(LogTemp, Warning, TEXT("[gameflow] ConnectPlayer %s: %s"), *Id, *Err.Message);
    }));
}

void AMyServerGameMode::Logout(AController* Exiting)
{
    Super::Logout(Exiting);
    FString Id;
    if (PlayerIds.RemoveAndCopyValue(Cast<APlayerController>(Exiting), Id))
        GF()->DisconnectPlayer(Id, FGfRemoveResult::CreateLambda([](const FGameFlowError&, bool, const FPlayerList&) {}));
}

void AMyServerGameMode::EndMatchAndShutdown()
{
    GF()->Shutdown(FGfVoidResult::CreateLambda([](const FGameFlowError&) { FGenericPlatformMisc::RequestExit(false); }));
}
```

**Notes:**
- **Player ids:** the player id comes from the client's travel URL options (`?PlayerId=`). In production, also verify a backend-issued token in `PreLogin` rather than trusting the id.
- **Port:** Unreal takes it from the command line (`-port=`), not from code. The managed Unreal template passes **no** args and breaks if launch options are set, so use the custom Dockerfile + `entrypoint.sh` from build-packaging.md: it runs `-port="$GAMEFLOW_DEFAULT_PORT"`.
- **Shutdown:** `Deinitialize()` sends shutdown when the process exits, including on SIGTERM. Still call `EndMatchAndShutdown()` at match end.

## Local mode

```bash
GAMEFLOW_MAX_PLAYERS=4 GAMEFLOW_PAYLOAD='{"match_id":"local-1","teams":[{"team_index":0,"players":[{"player_id":"alice"}]}]}' \
  ./MyGameServer.sh -log -port=7777
```

- Off GameFlow, lifecycle calls succeed immediately and players are tracked in memory.
- `GAMEFLOW_SDK_MODE=local|sidecar` forces a mode.
