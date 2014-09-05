# 
# File: NuGet.New-PrigStubsCs.ps1
# 
# Author: Akira Sugiura (urasandesu@gmail.com)
# 
# 
# Copyright (c) 2012 Akira Sugiura
#  
#  This software is MIT License.
#  
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#  
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#  
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.
#



function New-PrigStubsCs {
    param ($WorkDirectory, $AssemblyInfo, $Section, $TargetFrameworkVersion)

    $results = New-Object System.Collections.ArrayList
    
    foreach ($namespaceGrouped in $Section.GroupedStubs) {
        $dir = $namespaceGrouped.Key -replace '\.', '\'

        foreach ($declTypeGrouped in $namespaceGrouped) {
            $content = @"

using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.CompilerServices;
using Urasandesu.Prig.Framework;

namespace $(ConcatIfNonEmpty $namespaceGrouped.Key '.')Prig
{
    public class P$(ToClassNameFromType $declTypeGrouped.Key) : P$(ToBaseNameFromType $declTypeGrouped.Key) $(ToGenericParameterConstraintsFromType $declTypeGrouped.Key)
    {
        public static IndirectionBehaviors DefaultBehavior { get; internal set; }

"@ + $(foreach ($stub in $declTypeGrouped | ? { IsSignaturePublic $_ }) {
@"

        public static zz$(ToClassNameFromStub $stub) $(ToClassNameFromStub $stub)() $(ToGenericParameterConstraintsFromStub $stub)
        {
            return new zz$(ToClassNameFromStub $stub)();
        }

        [EditorBrowsable(EditorBrowsableState.Never)]
        public class zz$(ToClassNameFromStub $stub) : IBehaviorPreparable $(ToGenericParameterConstraintsFromStub $stub)
        {
            public $(ToClassNameFromType $stub.IndirectionDelegate) Body
            {
                get
                {
                    var holder = LooseCrossDomainAccessor.GetOrRegister<IndirectionHolder<$(ToClassNameFromType $stub.IndirectionDelegate)>>();
                    return holder.GetOrDefault(Info);
                }
                set
                {
                    var holder = LooseCrossDomainAccessor.GetOrRegister<IndirectionHolder<$(ToClassNameFromType $stub.IndirectionDelegate)>>();
                    if (value == null)
                    {
                        holder.Remove(Info);
                    }
                    else
                    {
                        holder.AddOrUpdate(Info, value);
                        RuntimeHelpers.PrepareDelegate(Body);
                    }
                }
            }

            public void Prepare(IndirectionBehaviors defaultBehavior)
            {
                var behavior = IndirectionDelegates.CreateDelegateOfDefaultBehavior$(ToClassNameFromType $stub.IndirectionDelegate)(defaultBehavior);
                Body = behavior;
            }

            public IndirectionInfo Info
            {
                get
                {
                    var info = new IndirectionInfo();
                    info.AssemblyName = "$($AssemblyInfo.FullName)";
                    info.Token = TokenOf$($stub.Name);
                    return info;
                }
            }
"@ + $(if (!$stub.Target.IsStatic -and !$declTypeGrouped.Key.IsValueType) {
@"

            internal void SetTargetInstanceBody($(ToClassNameFromType $declTypeGrouped.Key) target, $(ToClassNameFromType $stub.IndirectionDelegate) value)
            {
                RuntimeHelpers.PrepareDelegate(value);

                var holder = LooseCrossDomainAccessor.GetOrRegister<GenericHolder<TaggedBag<zz$(ToClassNameFromStub $stub), Dictionary<$(ToClassNameFromType $declTypeGrouped.Key), TargetSettingValue<$(ToClassNameFromType $stub.IndirectionDelegate)>>>>>();
                if (holder.Source.Value == null)
                    holder.Source = TaggedBagFactory<zz$(ToClassNameFromStub $stub)>.Make(new Dictionary<$(ToClassNameFromType $declTypeGrouped.Key), TargetSettingValue<$(ToClassNameFromType $stub.IndirectionDelegate)>>());

                if (holder.Source.Value.Count == 0)
                {
                    var behavior = Body == null ? IndirectionDelegates.CreateDelegateOfDefaultBehavior$(ToClassNameFromType $stub.IndirectionDelegate)(IndirectionBehaviors.Fallthrough) : Body;
                    RuntimeHelpers.PrepareDelegate(behavior);
                    holder.Source.Value[target] = new TargetSettingValue<$(ToClassNameFromType $stub.IndirectionDelegate)>(behavior, value);
                    {
                        // Prepare JIT
                        var original = holder.Source.Value[target].Original;
                        var indirection = holder.Source.Value[target].Indirection;
                    }
                    Body = IndirectionDelegates.CreateDelegateExecutingDefaultOr$(ToClassNameFromType $stub.IndirectionDelegate)(behavior, holder.Source.Value);
                }
                else
                {
                    Debug.Assert(Body != null);
                    var before = holder.Source.Value[target];
                    holder.Source.Value[target] = new TargetSettingValue<$(ToClassNameFromType $stub.IndirectionDelegate)>(before.Original, value);
                }
            }

            internal void RemoveTargetInstanceBody($(ToClassNameFromType $declTypeGrouped.Key) target)
            {
                var holder = LooseCrossDomainAccessor.GetOrRegister<GenericHolder<TaggedBag<zz$(ToClassNameFromStub $stub), Dictionary<$(ToClassNameFromType $declTypeGrouped.Key), TargetSettingValue<$(ToClassNameFromType $stub.IndirectionDelegate)>>>>>();
                if (holder.Source.Value == null)
                    return;

                if (holder.Source.Value.Count == 0)
                    return;

                var before = default(TargetSettingValue<$(ToClassNameFromType $stub.IndirectionDelegate)>);
                if (holder.Source.Value.ContainsKey(target))
                    before = holder.Source.Value[target];
                holder.Source.Value.Remove(target);
                if (holder.Source.Value.Count == 0)
                    Body = before.Original;
            }
"@}) + @"

        }

"@}) + @"


        public static TypeBehaviorSetting ExcludeGeneric()
        {
            var preparables = typeof(P$(ToClassNameFromType $declTypeGrouped.Key)).GetNestedTypes().
                                          Where(_ => _.GetInterface(typeof(IBehaviorPreparable).FullName) != null).
                                          Where(_ => !_.IsGenericType).
                                          Select(_ => Activator.CreateInstance(_)).
                                          Cast<IBehaviorPreparable>();
            var setting = new TypeBehaviorSetting();
            foreach (var preparable in preparables)
                setting.Include(preparable);
            return setting;
        }

        public class TypeBehaviorSetting : BehaviorSetting
        {
"@ + $(foreach ($stub in $declTypeGrouped | ? { ($declTypeGrouped.Key.IsGenericType -or $_.Target.IsGenericMethod) -and (IsSignaturePublic $_) }) {
@"

            public TypeBehaviorSetting Include$(ToClassNameFromStub $stub)() $(ToGenericParameterConstraintsFromStub $stub)
            {
                Include(P$(ToClassNameFromType $declTypeGrouped.Key).$(ToClassNameFromStub $stub)());
                return this;
            }

"@}) + @"

            public override IndirectionBehaviors DefaultBehavior
            {
                set
                {
                    P$(ToClassNameFromType $declTypeGrouped.Key).DefaultBehavior = value;
                    foreach (var preparable in Preparables)
                        preparable.Prepare(P$(ToClassNameFromType $declTypeGrouped.Key).DefaultBehavior);
                }
            }
        }
    }
}
"@
            $result = 
                New-Object psobject | 
                    Add-Member NoteProperty 'Path' ([System.IO.Path]::Combine($WorkDirectory, "$(ConcatIfNonEmpty $dir '\')P$($declTypeGrouped.Key.Name).cs")) -PassThru | 
                    Add-Member NoteProperty 'Content' $content -PassThru
            [Void]$results.Add($result)
        }
    }

    ,$results
}
