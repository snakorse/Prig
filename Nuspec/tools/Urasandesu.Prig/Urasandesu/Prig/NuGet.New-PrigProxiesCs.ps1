# 
# File: NuGet.New-PrigProxiesCs.ps1
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



function New-PrigProxiesCs {
    param ($WorkDirectory, $AssemblyInfo, $Section, $TargetFrameworkVersion)

    $results = New-Object System.Collections.ArrayList
    
    foreach ($namespaceGrouped in $Section.GroupedStubs) {
        $dir = $namespaceGrouped.Key -replace '\.', '\'

        foreach ($declTypeGrouped in $namespaceGrouped) {
            if (!(IsPublic $declTypeGrouped.Key) -or $declTypeGrouped.Key.IsValueType) { continue }
            $hasAnyInstanceMember = $false
            $content = @"

using System;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.Serialization;
using Urasandesu.Prig.Framework;

namespace $(ConcatIfNonEmpty $namespaceGrouped.Key '.')Prig
{
    public class PProxy$(ToClassNameFromType $declTypeGrouped.Key) $(ToGenericParameterConstraintsFromType $declTypeGrouped.Key)
    {
        $(ToFullNameFromType $declTypeGrouped.Key) m_target;
        
        public PProxy$(StripGenericParameterCount $declTypeGrouped.Key.Name)()
        {
            m_target = ($(ToFullNameFromType $declTypeGrouped.Key))FormatterServices.GetUninitializedObject(typeof($(ToFullNameFromType $declTypeGrouped.Key)));
        }

        public IndirectionBehaviors DefaultBehavior { get; internal set; }

"@ + $(foreach ($stub in $declTypeGrouped | ? { !$_.Target.IsStatic -and (IsSignaturePublic $_) -and ($_.Target -is [System.Reflection.MethodInfo]) }) {
        $hasAnyInstanceMember = $true
@"

        public zz$(ToClassNameFromStub $stub) $(ToClassNameFromStub $stub)() $(ToGenericParameterConstraintsFromStub $stub)
        {
            return new zz$(ToClassNameFromStub $stub)(m_target);
        }

        [EditorBrowsable(EditorBrowsableState.Never)]
        public class zz$(ToClassNameFromStub $stub) : IBehaviorPreparable $(ToGenericParameterConstraintsFromStub $stub)
        {
            $(ToFullNameFromType $declTypeGrouped.Key) m_target;

            public zz$(StripGenericParameterCount $stub.Alias)($(ToFullNameFromType $declTypeGrouped.Key) target)
            {
                m_target = target;
            }

            public $(ToClassNameFromType $stub.IndirectionDelegate) Body
            {
                get
                {
                    return P$(ToClassNameFromType $declTypeGrouped.Key).$(ToClassNameFromStub $stub)().Body;
                }
                set
                {
                    if (value == null)
                        P$(ToClassNameFromType $declTypeGrouped.Key).$(ToClassNameFromStub $stub)().RemoveTargetInstanceBody(m_target);
                    else
                        P$(ToClassNameFromType $declTypeGrouped.Key).$(ToClassNameFromStub $stub)().SetTargetInstanceBody(m_target, value);
                }
            }

            public void Prepare(IndirectionBehaviors defaultBehavior)
            {
                var behavior = IndirectionDelegates.CreateDelegateOfDefaultBehavior$(ToClassNameFromType $stub.IndirectionDelegate)(defaultBehavior);
                Body = behavior;
            }

            public IndirectionInfo Info
            {
                get { return P$(ToClassNameFromType $declTypeGrouped.Key).$(ToClassNameFromStub $stub)().Info; }
            }
        }
"@}) + @"


        public static implicit operator $(ToFullNameFromType $declTypeGrouped.Key)(PProxy$(ToClassNameFromType $declTypeGrouped.Key) @this)
        {
            return @this.m_target;
        }

        public InstanceBehaviorSetting ExcludeGeneric()
        {
            var preparables = typeof(PProxy$(ToClassNameFromType $declTypeGrouped.Key)).GetNestedTypes().
                                          Where(_ => _.GetInterface(typeof(IBehaviorPreparable).FullName) != null).
                                          Where(_ => !_.IsGenericType).
                                          Select(_ => Activator.CreateInstance(_, new object[] { m_target })).
                                          Cast<IBehaviorPreparable>();
            var setting = new InstanceBehaviorSetting(this);
            foreach (var preparable in preparables)
                setting.Include(preparable);
            return setting;
        }

        public class InstanceBehaviorSetting : BehaviorSetting
        {
            private PProxy$(ToClassNameFromType $declTypeGrouped.Key) m_this;

            public InstanceBehaviorSetting(PProxy$(ToClassNameFromType $declTypeGrouped.Key) @this)
            {
                m_this = @this;
            }
"@ + $(foreach ($stub in $declTypeGrouped | ? { ($declTypeGrouped.Key.IsGenericType -or $_.Target.IsGenericMethod) -and (IsSignaturePublic $_) }) {
@"

            public InstanceBehaviorSetting Include$(ToClassNameFromStub $stub)() $(ToGenericParameterConstraintsFromStub $stub)
            {
                Include(m_this.$(ToClassNameFromStub $stub)());
                return this;
            }

"@}) + @"

            public override IndirectionBehaviors DefaultBehavior
            {
                set
                {
                    m_this.DefaultBehavior = value;
                    foreach (var preparable in Preparables)
                        preparable.Prepare(m_this.DefaultBehavior);
                }
            }
        }
    }
}
"@
            if (!$hasAnyInstanceMember) { continue }

            $result = 
                New-Object psobject | 
                    Add-Member NoteProperty 'Path' ([System.IO.Path]::Combine($WorkDirectory, "$(ConcatIfNonEmpty $dir '\')PProxy$($declTypeGrouped.Key.Name).cs")) -PassThru | 
                    Add-Member NoteProperty 'Content' $content -PassThru
            [Void]$results.Add($result)
        }
    }

    ,$results
}
