{
 ---------------------------------------------------------------------------
 FpDebugDebuggerWorkThreads
 ---------------------------------------------------------------------------

 ***************************************************************************
 *                                                                         *
 *   This source is free software; you can redistribute it and/or modify   *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 *   This code is distributed in the hope that it will be useful, but      *
 *   WITHOUT ANY WARRANTY; without even the implied warranty of            *
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *
 *   General Public License for more details.                              *
 *                                                                         *
 *   A copy of the GNU General Public License is available on the World    *
 *   Wide Web at <http://www.gnu.org/copyleft/gpl.html>. You can also      *
 *   obtain it by writing to the Free Software Foundation,                 *
 *   Inc., 51 Franklin Street - Fifth Floor, Boston, MA 02110-1335, USA.   *
 *                                                                         *
 ***************************************************************************
}

unit FpDebugDebuggerWorkThreads;

(*
  This unit contains the classes for executing work in the worker thread:
  - The general structure of the classes
  - The code that is to be executed in the worker thread
      procedure DoExecute;

  - The classes are extended in the main FpDebugDebugger unit with any code
    running in the main debugger thread.

  This split accross the units should help with identifying what may be accessed
  in the worker thread.
*)

{$mode objfpc}{$H+}
{$TYPEDADDRESS on}
{$ModeSwitch advancedrecords}

interface

uses
  FpDebugDebuggerUtils, DbgIntfDebuggerBase, DbgIntfBaseTypes, FpDbgClasses,
  FpDbgUtil, FPDbgController, FpPascalBuilder, FpdMemoryTools, FpDbgInfo,
  FpPascalParser, FpErrorMessages, Forms, fgl, math, Classes, sysutils, LazLoggerBase;

type

  TFpDbgAsyncMethod = procedure() of object;

  TFpDebugDebuggerBase = class(TDebuggerIntf)
  protected
    FDbgController: TDbgController;
    FMemManager: TFpDbgMemManager;
    FLockList: TFpDbgLockList;
    FWorkQueue: TFpThreadPriorityWorkerQueue;
  end;

  { TFpDbgDebggerThreadWorkerItem }

  TFpDbgDebggerThreadWorkerItem = class(TFpThreadPriorityWorkerItem)
  protected type
    THasQueued = (hqNotQueued, hqQueued, hqBlocked);
  protected
    FDebugger: TFpDebugDebuggerBase;
    FHasQueued: THasQueued;
  public
    constructor Create(ADebugger: TFpDebugDebuggerBase; APriority: TFpThreadWorkerPriority);

    procedure Queue(aMethod: TDataEvent; Data: PtrInt = 0);
    (* Unqueue_DecRef also prevents new queuing
       Unqueue_DecRef allows for destruction (no more access to object)
       => therefor UnQueue_DecRef and ALL/most methods executing  unqueue_DecRef are named *_DecRef
    *)
    procedure UnQueue_DecRef(ABlockQueuing: Boolean = True);
  end;

  { TFpDbgDebggerThreadWorkerLinkedItem }

  TFpDbgDebggerThreadWorkerLinkedItem = class(TFpDbgDebggerThreadWorkerItem)
  protected
    FNextWorker: TFpDbgDebggerThreadWorkerLinkedItem; // linked list for use by TFPCallStackSupplier
    procedure DoRemovedFromLinkedList; virtual;
  end;

  { TFpDbgDebggerThreadWorkerLinkedList }

  TFpDbgDebggerThreadWorkerLinkedList = object
  private
    FNextWorker: TFpDbgDebggerThreadWorkerLinkedItem;
  public
    procedure Add(AWorkItem: TFpDbgDebggerThreadWorkerLinkedItem); // Does not add ref / uses existing ref
    procedure ClearFinishedWorkers;
    procedure RequestStopForWorkers;
    procedure WaitForWorkers(AStop: Boolean); // Only call in IDE thread (main thread)
  end;

  { TFpThreadWorkerControllerRun }

  TFpThreadWorkerControllerRun = class(TFpDbgDebggerThreadWorkerItem)
  private
    FWorkerThreadId: TThreadID;
  protected
    FStartSuccessfull: boolean;
    procedure DoExecute; override;
  public
    constructor Create(ADebugger: TFpDebugDebuggerBase);
    property StartSuccesfull: boolean read FStartSuccessfull;
    property WorkerThreadId: TThreadID read FWorkerThreadId;
  end;

  { TFpThreadWorkerRunLoop }

  TFpThreadWorkerRunLoop = class(TFpDbgDebggerThreadWorkerItem)
  protected
    procedure LoopFinished_DecRef(Data: PtrInt = 0); virtual; abstract;
    procedure DoExecute; override;
  public
    constructor Create(ADebugger: TFpDebugDebuggerBase);
  end;

  { TFpThreadWorkerRunLoopAfterIdle }

  TFpThreadWorkerRunLoopAfterIdle = class(TFpDbgDebggerThreadWorkerItem)
  protected
    procedure CheckIdleOrRun_DecRef(Data: PtrInt = 0); virtual; abstract;
    procedure DoExecute; override;
  public
    constructor Create(ADebugger: TFpDebugDebuggerBase);
  end;

  { TFpThreadWorkerAsyncMeth }

  TFpThreadWorkerAsyncMeth = class(TFpDbgDebggerThreadWorkerItem)
  protected
    FAsyncMethod: TFpDbgAsyncMethod;
    procedure DoExecute; override;
  public
    constructor Create(ADebugger: TFpDebugDebuggerBase; AnAsyncMethod: TFpDbgAsyncMethod);
  end;

  { TFpThreadWorkerPrepareCallStackEntryList }

  TFpThreadWorkerPrepareCallStackEntryList = class(TFpDbgDebggerThreadWorkerLinkedItem)
  (* Do not accesss   CallStackEntryList.Items[]   while this is running *)
  protected
    FRequiredMinCount: Integer;
    FThread: TDbgThread;
    procedure PrepareCallStackEntryList(AFrameRequired: Integer; AThread: TDbgThread);
    procedure DoExecute; override;
  public
    constructor Create(ADebugger: TFpDebugDebuggerBase; ARequiredMinCount: Integer; APriority: TFpThreadWorkerPriority = twpStack);
    constructor Create(ADebugger: TFpDebugDebuggerBase; ARequiredMinCount: Integer; AThread: TDbgThread);
  end;

  { TFpThreadWorkerCallStackCount }

  TFpThreadWorkerCallStackCount = class(TFpThreadWorkerPrepareCallStackEntryList)
  protected
    procedure UpdateCallstack_DecRef(Data: PtrInt = 0); virtual; abstract;
    procedure DoExecute; override;
    procedure DoRemovedFromLinkedList; override; // _DecRef
  end;

  { TFpThreadWorkerCallEntry }

  TFpThreadWorkerCallEntry = class(TFpThreadWorkerPrepareCallStackEntryList)
  protected
    FCallstackIndex: Integer;
    FDbgCallStack: TDbgCallstackEntry;
    FParamAsString: String;
    procedure UpdateCallstackEntry_DecRef(Data: PtrInt = 0); virtual; abstract;
    procedure DoExecute; override;
    procedure DoRemovedFromLinkedList; override; // _DecRef
  end;

  { TFpThreadWorkerThreads }

  TFpThreadWorkerThreads = class(TFpThreadWorkerPrepareCallStackEntryList)
  protected
    procedure UpdateThreads_DecRef(Data: PtrInt = 0); virtual; abstract;
    procedure DoExecute; override;
  public
    constructor Create(ADebugger: TFpDebugDebuggerBase);
  end;

  { TFpThreadWorkerLocals }

  TFpThreadWorkerLocals = class(TFpDbgDebggerThreadWorkerLinkedItem)
  protected type
    TResultEntry = record
      Name, Value: String;
      class operator = (a, b: TResultEntry): Boolean;
    end;
    TResultList = specialize TFPGList<TResultEntry>;
  protected
    FThreadId, FStackFrame: Integer;
    FResults: TResultList;
    procedure UpdateLocals_DecRef(Data: PtrInt = 0); virtual; abstract;
    procedure DoExecute; override;
  public
    destructor Destroy; override;
  end;

  { TFpThreadWorkerEvaluate }

  TFpThreadWorkerEvaluate = class(TFpDbgDebggerThreadWorkerLinkedItem)
  protected
    function EvaluateExpression(const AnExpression: String;
                                AStackFrame, AThreadId: Integer;
                                ADispFormat: TWatchDisplayFormat;
                                ARepeatCnt: Integer;
                                AnEvalFlags: TDBGEvaluateFlags;
                                out AResText: String;
                                out ATypeInfo: TDBGType
                               ): Boolean;
  public
  end;

  { TFpThreadWorkerEvaluateExpr }

  TFpThreadWorkerEvaluateExpr = class(TFpThreadWorkerEvaluate)
  private
    FExpression: String;
    FStackFrame, FThreadId: Integer;
    FDispFormat: TWatchDisplayFormat;
    FRepeatCnt: Integer;
    FEvalFlags: TDBGEvaluateFlags;
  protected
    FRes: Boolean;
    FResText: String;
    FResDbgType: TDBGType;
    procedure DoExecute; override;
  public
    constructor Create(ADebugger: TFpDebugDebuggerBase;
                       APriority: TFpThreadWorkerPriority;
                       const AnExpression: String;
                       AStackFrame, AThreadId: Integer;
                       ADispFormat: TWatchDisplayFormat;
                       ARepeatCnt: Integer;
                       AnEvalFlags: TDBGEvaluateFlags
                      );
    function DebugText: String; override;
  end;

  { TFpThreadWorkerCmdEval }

  TFpThreadWorkerCmdEval = class(TFpThreadWorkerEvaluateExpr)
  protected
    FCallback: TDBGEvaluateResultCallback;
    procedure DoCallback_DecRef(Data: PtrInt = 0);
    procedure DoExecute; override;
  public
    constructor Create(ADebugger: TFpDebugDebuggerBase;
                       APriority: TFpThreadWorkerPriority;
                       const AnExpression: String;
                       AStackFrame, AThreadId: Integer;
                       AnEvalFlags: TDBGEvaluateFlags;
                       ACallback: TDBGEvaluateResultCallback
                      );
    procedure Abort;
  end;

  { TFpThreadWorkerWatchValueEval }

  TFpThreadWorkerWatchValueEval = class(TFpThreadWorkerEvaluateExpr)
  protected
    procedure UpdateWatch_DecRef(Data: PtrInt = 0); virtual; abstract;
    procedure DoExecute; override;
  end;

implementation

{ TFpDbgDebggerThreadWorkerItem }

constructor TFpDbgDebggerThreadWorkerItem.Create(ADebugger: TFpDebugDebuggerBase;
  APriority: TFpThreadWorkerPriority);
begin
  inherited Create(APriority);
  FDebugger := ADebugger;
  AddRef;
end;

procedure TFpDbgDebggerThreadWorkerItem.Queue(aMethod: TDataEvent; Data: PtrInt
  );
begin
  FDebugger.FLockList.Lock;
  try
    if (FHasQueued <> hqBlocked) then begin
      assert(FHasQueued = hqNotQueued, 'TFpDbgDebggerThreadWorkerItem.Queue: FHasQueued = hqNotQueued');
      FHasQueued := hqQueued;
      AddRef;
      Application.QueueAsyncCall(aMethod, 0);
    end;
  finally
    FDebugger.FLockList.UnLock;
  end;
end;

procedure TFpDbgDebggerThreadWorkerItem.UnQueue_DecRef(ABlockQueuing: Boolean);
var
  HasQ: THasQueued;
begin
  FDebugger.FLockList.Lock;
  HasQ := FHasQueued;
  if ABlockQueuing then begin
    FHasQueued := hqBlocked;
    FDebugger.FLockList.UnLock; // unlock first.
    Application.RemoveAsyncCalls(Self);
  end
  else begin
    FHasQueued := hqNotQueued;
    try
      Application.RemoveAsyncCalls(Self);
    finally
      FDebugger.FLockList.UnLock;
    end;
  end;

  if HasQ = hqQueued then
    DecRef; // may call destroy
end;

{ TFpDbgDebggerThreadWorkerLinkedItem }

procedure TFpDbgDebggerThreadWorkerLinkedItem.DoRemovedFromLinkedList;
begin
  //
end;

{ TFpDbgDebggerThreadWorkerLinkedList }

procedure TFpDbgDebggerThreadWorkerLinkedList.Add(
  AWorkItem: TFpDbgDebggerThreadWorkerLinkedItem);
begin
  AWorkItem.FNextWorker := FNextWorker;
  FNextWorker := AWorkItem;
end;

procedure TFpDbgDebggerThreadWorkerLinkedList.ClearFinishedWorkers;
var
  WorkItem, w: TFpDbgDebggerThreadWorkerLinkedItem;
begin
  assert(system.ThreadID = classes.MainThreadID, 'TFpDbgDebggerThreadWorkerLinkedList.ClearFinishedCountWorkers: system.ThreadID = classes.MainThreadID');
  WorkItem := FNextWorker;
  while (WorkItem <> nil) and (WorkItem.RefCount = 1) do begin
    w := WorkItem;
    WorkItem := w.FNextWorker;
    //w.DoRemovedFromLinkedList;
    w.DecRef;
  end;
  FNextWorker := WorkItem;
end;

procedure TFpDbgDebggerThreadWorkerLinkedList.RequestStopForWorkers;
var
  WorkItem: TFpDbgDebggerThreadWorkerLinkedItem;
begin
  WorkItem := FNextWorker;
  while (WorkItem <> nil) do begin
    WorkItem.RequestStop;
    WorkItem := WorkItem.FNextWorker;
  end;
end;

procedure TFpDbgDebggerThreadWorkerLinkedList.WaitForWorkers(AStop: Boolean);
var
  WorkItem, w: TFpDbgDebggerThreadWorkerLinkedItem;
begin
  assert(system.ThreadID = classes.MainThreadID, 'TFpDbgDebggerThreadWorkerLinkedList.WaitForWorkers: system.ThreadID = classes.MainThreadID');
  if AStop then
    RequestStopForWorkers;

  WorkItem := FNextWorker;
  FNextWorker := nil;
  while (WorkItem <> nil) do begin
    w := WorkItem;
    WorkItem := w.FNextWorker;
    if w.IsCancelled then
      w.FDebugger.FWorkQueue.RemoveItem(w)
    else
      w.FDebugger.FWorkQueue.WaitForItem(w);
    w.DoRemovedFromLinkedList;
    w.DecRef;
  end;
end;

{ TFpThreadWorkerControllerRun }

procedure TFpThreadWorkerControllerRun.DoExecute;
begin
  FStartSuccessfull := FDebugger.FDbgController.Run;
  FWorkerThreadId := ThreadID;
end;

constructor TFpThreadWorkerControllerRun.Create(ADebugger: TFpDebugDebuggerBase);
begin
  inherited Create(ADebugger, twpContinue);
end;

{ TFpThreadWorkerRunLoop }

procedure TFpThreadWorkerRunLoop.DoExecute;
begin
  FDebugger.FDbgController.ProcessLoop;
  Queue(@LoopFinished_DecRef);
end;

constructor TFpThreadWorkerRunLoop.Create(ADebugger: TFpDebugDebuggerBase);
begin
  inherited Create(ADebugger, twpContinue);
end;

{ TFpThreadWorkerRunLoopAfterIdle }

procedure TFpThreadWorkerRunLoopAfterIdle.DoExecute;
begin
  Queue(@CheckIdleOrRun_DecRef);
end;

constructor TFpThreadWorkerRunLoopAfterIdle.Create(ADebugger: TFpDebugDebuggerBase);
begin
  inherited Create(ADebugger, twpContinue);
end;

{ TFpThreadWorkerAsyncMeth }

procedure TFpThreadWorkerAsyncMeth.DoExecute;
begin
  FAsyncMethod();
end;

constructor TFpThreadWorkerAsyncMeth.Create(ADebugger: TFpDebugDebuggerBase;
  AnAsyncMethod: TFpDbgAsyncMethod);
begin
  inherited Create(ADebugger, twpUser);
  FAsyncMethod := AnAsyncMethod;
end;

{ TFpThreadWorkerPrepareCallStackEntryList }

procedure TFpThreadWorkerPrepareCallStackEntryList.PrepareCallStackEntryList(
  AFrameRequired: Integer; AThread: TDbgThread);
var
  ThreadCallStack: TDbgCallstackEntryList;
  CurCnt, ReqCnt: Integer;
begin
  ThreadCallStack := AThread.CallStackEntryList;

  if ThreadCallStack = nil then begin
    AThread.PrepareCallStackEntryList(-2); // Only create the list
    ThreadCallStack := AThread.CallStackEntryList;
    if ThreadCallStack = nil then
      exit;
  end;

  FDebugger.FLockList.GetLockFor(ThreadCallStack);
  try
    CurCnt := ThreadCallStack.Count;
    while (not StopRequested) and (FRequiredMinCount > CurCnt) and
          (not ThreadCallStack.HasReadAllAvailableFrames)
    do begin
      ReqCnt := Min(CurCnt + 5, FRequiredMinCount);
      AThread.PrepareCallStackEntryList(ReqCnt);
      CurCnt := ThreadCallStack.Count;
      if CurCnt < ReqCnt then
        exit;
    end;
  finally
    FDebugger.FLockList.FreeLockFor(ThreadCallStack);
  end;
end;

procedure TFpThreadWorkerPrepareCallStackEntryList.DoExecute;
var
  t: TDbgThread;
begin
  if FRequiredMinCount < 0 then
    exit;
  if FThread = nil then begin
    for t in FDebugger.FDbgController.CurrentProcess.ThreadMap do begin
      PrepareCallStackEntryList(FRequiredMinCount, t);
      if StopRequested then
        break;
    end;
  end
  else
    PrepareCallStackEntryList(FRequiredMinCount, FThread);
end;

constructor TFpThreadWorkerPrepareCallStackEntryList.Create(
  ADebugger: TFpDebugDebuggerBase; ARequiredMinCount: Integer;
  APriority: TFpThreadWorkerPriority);
begin
  inherited Create(ADebugger, APriority);
  FRequiredMinCount := ARequiredMinCount;
  FThread := nil;
end;

constructor TFpThreadWorkerPrepareCallStackEntryList.Create(
  ADebugger: TFpDebugDebuggerBase; ARequiredMinCount: Integer; AThread: TDbgThread);
begin
  Create(ADebugger, ARequiredMinCount);
  FThread := AThread;
end;

{ TFpThreadWorkerCallStackCount }

procedure TFpThreadWorkerCallStackCount.DoExecute;
begin
  inherited DoExecute;
  Queue(@UpdateCallstack_DecRef);
end;

procedure TFpThreadWorkerCallStackCount.DoRemovedFromLinkedList;
begin
  inherited DoRemovedFromLinkedList;
  UpdateCallstack_DecRef;  // This trigger PrepareRange => but that still needs to be exec in thread? (or wait for lock)
end;

{ TFpThreadWorkerCallEntry }

procedure TFpThreadWorkerCallEntry.DoExecute;
var
  PrettyPrinter: TFpPascalPrettyPrinter;
  Prop: TFpDebugDebuggerProperties;
begin
  inherited DoExecute;

  FDbgCallStack := FThread.CallStackEntryList[FCallstackIndex];
  if (FDbgCallStack <> nil) and (not StopRequested) then begin
    Prop := TFpDebugDebuggerProperties(FDebugger.GetProperties);
    PrettyPrinter := TFpPascalPrettyPrinter.Create(DBGPTRSIZE[FDebugger.FDbgController.CurrentProcess.Mode]);
    PrettyPrinter.MemManager := FDebugger.FMemManager;

    FDebugger.FMemManager.MemLimits.MaxArrayLen            := Prop.MemLimits.MaxStackArrayLen;
    FDebugger.FMemManager.MemLimits.MaxStringLen           := Prop.MemLimits.MaxStackStringLen;
    FDebugger.FMemManager.MemLimits.MaxNullStringSearchLen := Prop.MemLimits.MaxStackNullStringSearchLen;

    FParamAsString := FDbgCallStack.GetParamsAsString(PrettyPrinter);
    PrettyPrinter.Free;

    FDebugger.FMemManager.MemLimits.MaxArrayLen            := Prop.MemLimits.MaxArrayLen;
    FDebugger.FMemManager.MemLimits.MaxStringLen           := Prop.MemLimits.MaxStringLen;
    FDebugger.FMemManager.MemLimits.MaxNullStringSearchLen := Prop.MemLimits.MaxNullStringSearchLen;
  end;

  Queue(@UpdateCallstackEntry_DecRef);
end;

procedure TFpThreadWorkerCallEntry.DoRemovedFromLinkedList;
begin
  inherited DoRemovedFromLinkedList;
  UpdateCallstackEntry_DecRef;
end;

{ TFpThreadWorkerThreads }

procedure TFpThreadWorkerThreads.DoExecute;
begin
  inherited DoExecute;
  Queue(@UpdateThreads_DecRef);
end;

constructor TFpThreadWorkerThreads.Create(ADebugger: TFpDebugDebuggerBase);
begin
  inherited Create(ADebugger, 1, twpThread);
end;

{ TFpThreadWorkerLocals.TResultEntry }

class operator TFpThreadWorkerLocals.TResultEntry. = (a, b: TResultEntry
  ): Boolean;
begin
  Result := False;
  assert(False, 'TFpThreadWorkerLocals.TResultEntry.=: False');
end;

{ TFpThreadWorkerLocals }

procedure TFpThreadWorkerLocals.DoExecute;
var
  LocalScope: TFpDbgSymbolScope;
  ProcVal, m: TFpValue;
  PrettyPrinter: TFpPascalPrettyPrinter;
  i: Integer;
  r: TResultEntry;
begin
  LocalScope := FDebugger.FDbgController.CurrentProcess.FindSymbolScope(FThreadId, FStackFrame);
  if (LocalScope = nil) or (LocalScope.SymbolAtAddress = nil) then begin
    LocalScope.ReleaseReference;
    exit;
  end;

  ProcVal := LocalScope.ProcedureAtAddress;
  if (ProcVal = nil) then begin
    LocalScope.ReleaseReference;
    exit;
  end;

  PrettyPrinter := TFpPascalPrettyPrinter.Create(LocalScope.SizeOfAddress);
  PrettyPrinter.MemManager := LocalScope.MemManager;
  PrettyPrinter.MemManager.DefaultContext := LocalScope.LocationContext;

  FResults := TResultList.Create;
  for i := 0 to ProcVal.MemberCount - 1 do begin
    m := ProcVal.Member[i];
    if m <> nil then begin
      if m.DbgSymbol <> nil then
        r.Name := m.DbgSymbol.Name
      else
        r.Name := '';
      //if not StopRequested then // finish getting all names?
      PrettyPrinter.PrintValue(r.Value, m);
      m.ReleaseReference;
      FResults.Add(r);
    end;
    if StopRequested then
      Break;
  end;
  PrettyPrinter.Free;
  ProcVal.ReleaseReference;
  LocalScope.ReleaseReference;

  Queue(@UpdateLocals_DecRef);
end;

destructor TFpThreadWorkerLocals.Destroy;
begin
  FResults.Free;
  inherited Destroy;
end;

{ TFpThreadWorkerEvaluate }

function TFpThreadWorkerEvaluate.EvaluateExpression(const AnExpression: String;
  AStackFrame, AThreadId: Integer; ADispFormat: TWatchDisplayFormat;
  ARepeatCnt: Integer; AnEvalFlags: TDBGEvaluateFlags; out AResText: String;
  out ATypeInfo: TDBGType): Boolean;
var
  WatchScope: TFpDbgSymbolScope;
  APasExpr, PasExpr2: TFpPascalExpression;
  PrettyPrinter: TFpPascalPrettyPrinter;
  ResValue: TFpValue;
  CastName, ResText2: String;
begin
  Result := False;
  AResText := '';
  ATypeInfo := nil;

  WatchScope := FDebugger.FDbgController.CurrentProcess.FindSymbolScope(AThreadId, AStackFrame);
  if WatchScope = nil then
    exit;

  WatchScope.MemManager.DefaultContext := WatchScope.LocationContext;

  APasExpr := nil;
  PrettyPrinter := nil;
  try
    APasExpr := TFpPascalExpression.Create(AnExpression, WatchScope);
    APasExpr.ResultValue; // trigger full validation
    if not APasExpr.Valid then begin
      AResText := ErrorHandler.ErrorAsString(APasExpr.Error);
      exit;
    end;

    ResValue := APasExpr.ResultValue;
    if ResValue = nil then begin
      AResText := 'Error';
      exit;
    end;

    if StopRequested then
      exit;
    if (ResValue.Kind = skClass) and (ResValue.AsCardinal <> 0) and
       (not IsError(ResValue.LastError)) and (defClassAutoCast in AnEvalFlags)
    then begin
      if ResValue.GetInstanceClassName(CastName) then begin
        PasExpr2 := TFpPascalExpression.Create(CastName+'('+AnExpression+')', WatchScope);
        PasExpr2.ResultValue;
        if PasExpr2.Valid then begin
          APasExpr.Free;
          APasExpr := PasExpr2;
          ResValue := APasExpr.ResultValue;
        end
        else
          PasExpr2.Free;
      end
      else begin
        ResValue.ResetError; // in case GetInstanceClassName did set an error
        // TODO: indicate that typecasting to instance failed
      end;
    end;

    if StopRequested then
      exit;

    PrettyPrinter := TFpPascalPrettyPrinter.Create(WatchScope.SizeOfAddress);
    PrettyPrinter.MemManager := WatchScope.MemManager;

    if defNoTypeInfo in AnEvalFlags then
      Result := PrettyPrinter.PrintValue(AResText, ResValue, ADispFormat, ARepeatCnt)
    else
      Result := PrettyPrinter.PrintValue(AResText, ATypeInfo, ResValue, ADispFormat, ARepeatCnt);

    // PCHAR/String
    if Result and APasExpr.HasPCharIndexAccess and not IsError(ResValue.LastError) then begin
    // TODO: Only dwarf 2
      APasExpr.FixPCharIndexAccess := True;
      APasExpr.ResetEvaluation;
      ResValue := APasExpr.ResultValue;
      if (ResValue=nil) or (not PrettyPrinter.PrintValue(ResText2, ResValue, ADispFormat, ARepeatCnt)) then
        ResText2 := 'Failed';
      AResText := 'PChar: '+AResText+ LineEnding + 'String: '+ResText2;
    end;

    if Result then
      Result := not IsError(ResValue.LastError) // AResText should be set from Prettyprinter
    else
      AResText := 'Error';

    if not Result then
      FreeAndNil(ATypeInfo);
  finally
    PrettyPrinter.Free;
    APasExpr.Free;
    WatchScope.ReleaseReference;
  end;
end;

{ TFpThreadWorkerEvaluateExpr }

procedure TFpThreadWorkerEvaluateExpr.DoExecute;
begin
  FRes := EvaluateExpression(FExpression, FStackFrame, FThreadId,
    FDispFormat, FRepeatCnt, FEvalFlags, FResText, FResDbgType);
end;

constructor TFpThreadWorkerEvaluateExpr.Create(ADebugger: TFpDebugDebuggerBase;
  APriority: TFpThreadWorkerPriority; const AnExpression: String; AStackFrame,
  AThreadId: Integer; ADispFormat: TWatchDisplayFormat; ARepeatCnt: Integer;
  AnEvalFlags: TDBGEvaluateFlags);
begin
  inherited Create(ADebugger, APriority);
  FExpression := AnExpression;
  FStackFrame := AStackFrame;
  FThreadId := AThreadId;
  FDispFormat := ADispFormat;
  FRepeatCnt := ARepeatCnt;
  FEvalFlags := AnEvalFlags;
  FRes := False;
end;

function TFpThreadWorkerEvaluateExpr.DebugText: String;
begin
  Result := inherited DebugText;
  if self = nil then exit;
  Result := Format('%s Expr: "%s" T: %s S: %s', [Result, FExpression, dbgs(FThreadId), dbgs(FStackFrame)]);
end;

{ TFpThreadWorkerCmdEval }

procedure TFpThreadWorkerCmdEval.DoCallback_DecRef(Data: PtrInt);
var
  CB: TDBGEvaluateResultCallback;
begin
  assert(system.ThreadID = classes.MainThreadID, 'TFpThreadWorkerCmdEval.DoCallback_DecRef: system.ThreadID = classes.MainThreadID');
  try
    if FEvalFlags * [defNoTypeInfo, defSimpleTypeInfo, defFullTypeInfo] = [defNoTypeInfo] then
      FreeAndNil(FResText);

    if FCallback <> nil then begin
      CB := FCallback;
      FCallback := nil; // Ensure callback is never called a 2nd time (e.g. if Self.Abort is called, while in Callback)
      CB(Self, FRes, FResText, FResDbgType);
      // If Abort was called (during CB), then self is now invalid
      // Abort would be called, if a new Evaluate Request is made. FEvalWorkItem<>nil
    end;
  except
  end;

  UnQueue_DecRef;
end;

procedure TFpThreadWorkerCmdEval.DoExecute;
begin
  inherited DoExecute;
  Queue(@DoCallback_DecRef);
end;

constructor TFpThreadWorkerCmdEval.Create(ADebugger: TFpDebugDebuggerBase;
  APriority: TFpThreadWorkerPriority; const AnExpression: String; AStackFrame,
  AThreadId: Integer; AnEvalFlags: TDBGEvaluateFlags;
  ACallback: TDBGEvaluateResultCallback);
begin
  inherited Create(ADebugger, APriority, AnExpression, AStackFrame, AThreadId, wdfDefault, 0,
    AnEvalFlags);
  FCallback := ACallback;
end;

procedure TFpThreadWorkerCmdEval.Abort;
begin
  RequestStop;
  FDebugger.FWorkQueue.RemoveItem(Self);
  DoCallback_DecRef;
end;

{ TFpThreadWorkerWatchValueEval }

procedure TFpThreadWorkerWatchValueEval.DoExecute;
begin
  inherited DoExecute;
  Queue(@UpdateWatch_DecRef);
end;

end.

