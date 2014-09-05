﻿/* 
 * File: LooseCrossDomainAccessor.cs
 * 
 * Author: Akira Sugiura (urasandesu@gmail.com)
 * 
 * 
 * Copyright (c) 2014 Akira Sugiura
 *  
 *  This software is MIT License.
 *  
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *  
 *  The above copyright notice and this permission notice shall be included in
 *  all copies or substantial portions of the Software.
 *  
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 *  THE SOFTWARE.
 */


using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Threading;

namespace Urasandesu.Prig.Framework
{
    public class LooseCrossDomainAccessor
    {
        protected LooseCrossDomainAccessor() { }

        static readonly HashSet<Type> ms_registrations = new HashSet<Type>();

        public static void Register<T>() where T : InstanceHolder<T>
        {
            LooseCrossDomainAccessor<T>.Register();
            lock (ms_registrations)
                using (InstanceGetters.DisableProcessing())
                    ms_registrations.Add(typeof(T));
        }

        public static void Unload<T>() where T : InstanceHolder<T>
        {
            LooseCrossDomainAccessor<T>.Unload();
        }

        public static T Get<T>() where T : InstanceHolder<T>
        {
            return LooseCrossDomainAccessor<T>.Holder;
        }

        public static T GetOrRegister<T>() where T : InstanceHolder<T>
        {
            var holder = default(T);
            if ((holder = LooseCrossDomainAccessor<T>.HolderOrDefault) == null)
            {
                Register<T>();
                holder = LooseCrossDomainAccessor<T>.Holder;
            }
            return holder;
        }

        public static bool TryGet<T>(out T holder) where T : InstanceHolder<T>
        {
            holder = LooseCrossDomainAccessor<T>.HolderOrDefault;
            if (holder == null && !InstanceGetters.IsDisabledProcessing())
                holder = GetOrRegister<T>();
            return holder != null;
        }

        public static void Clear()
        {
            lock (ms_registrations)
            {
                using (InstanceGetters.DisableProcessing())
                {
                    var unloadMethods = ms_registrations.Select(_ => typeof(LooseCrossDomainAccessor<>).MakeGenericType(_)).
                                                         Select(_ => _.GetMethod("Unload")).
                                                         ToArray();
                    for (int i = 0; i < unloadMethods.Length; i++)
                        unloadMethods[i].Invoke(null, new object[0]);
                    InstanceGetters.Clear();
                }
            }
        }

        public static bool IsTypeOf(object obj, Type type)
        {
            if (obj == null)
                throw new ArgumentNullException("obj");

            if (type == null)
                throw new ArgumentNullException("type");

            return ToLooseDomainIdentity(obj.GetType()) == ToLooseDomainIdentity(type);
        }

        public static bool IsInstanceOfType(object obj, Type type)
        {
            if (type == null)
                throw new ArgumentNullException("type");

            var id = ToLooseDomainIdentity(type);
            return IsInstanceOfIdentity(obj, id);
        }

        public static bool IsInstanceOfIdentity(object obj, string id)
        {
            if (obj == null)
                return false;

            for (var _type = obj.GetType(); _type != null; _type = _type.BaseType)
                if (id == ToLooseDomainIdentity(_type))
                    return true;

            return false;
        }

        static string ToLooseDomainIdentity(Type type)
        {
            // Don't use AssemblyQualifiedName because the AppDomain may have different permission set from current AppDomain.
            // The property AssemblyQualifiedName tries load its assembly again, so FileLoadException will be thrown in this case.
            return type.FullName;
        }
    }

    public class LooseCrossDomainAccessor<T> where T : InstanceHolder<T>
    {
        static readonly object ms_lockObj = new object();
        static T ms_holder = null;
        static bool ms_ready = false;
        static readonly Type ms_t = typeof(T);
        static readonly string ms_key = ms_t.AssemblyQualifiedName;

        protected LooseCrossDomainAccessor() { }

        public static void Register()
        {
            using (InstanceGetters.DisableProcessing())
            {
                var instance = ms_t.GetProperty("Instance", BindingFlags.Public | BindingFlags.Static | BindingFlags.FlattenHierarchy);
                var instanceGetter = instance.GetGetMethod();
                RuntimeHelpers.PrepareMethod(instanceGetter.MethodHandle);
                var funcPtr = instanceGetter.MethodHandle.GetFunctionPointer();
                InstanceGetters.TryAdd(ms_key, funcPtr);
            }
        }

        static bool TryGetHolder(out T holder)
        {
            var funcPtr = default(IntPtr);
            if (!InstanceGetters.TryGet(ms_key, out funcPtr))
            {
                holder = null;
                return false;
            }
            else
            {
                using (InstanceGetters.DisableProcessing())
                {
                    var extractor = new DynamicMethod("Extractor", ms_t, null, ms_t.Module);
                    var gen = extractor.GetILGenerator();
                    if (IntPtr.Size == 4)
                    {
                        gen.Emit(OpCodes.Ldc_I4, funcPtr.ToInt32());
                    }
                    else if (IntPtr.Size == 8)
                    {
                        gen.Emit(OpCodes.Ldc_I8, funcPtr.ToInt64());
                    }
                    else
                    {
                        throw new NotSupportedException();
                    }
                    gen.EmitCalli(OpCodes.Calli, CallingConventions.Standard, ms_t, null, null);
                    gen.Emit(OpCodes.Ret);
                    holder = ((Func<T>)extractor.CreateDelegate(typeof(Func<T>)))();
                }
                holder.Prepare();
                return true;
            }
        }

        public static T Holder
        {
            get
            {
                if (!ms_ready)
                {
                    lock (ms_lockObj)
                    {
                        if (!ms_ready)
                        {
                            var holder = default(T);
                            if (!TryGetHolder(out holder))
                                using (InstanceGetters.DisableProcessing())
                                    throw new InvalidOperationException(string.Format("T({0}) has not been registered yet. Please call Register method.", typeof(T)));
                            ms_holder = holder;
                            using (InstanceGetters.DisableProcessing())
                                Thread.MemoryBarrier();
                            ms_ready = true;
                        }
                    }
                }
                return ms_holder;
            }
        }

        public static T HolderOrDefault
        {
            get
            {
                if (!ms_ready)
                {
                    lock (ms_lockObj)
                    {
                        if (!ms_ready)
                        {
                            var holder = default(T);
                            if (TryGetHolder(out holder))
                            {
                                ms_holder = holder;
                                using (InstanceGetters.DisableProcessing())
                                    Thread.MemoryBarrier();
                                ms_ready = true;
                            }
                        }
                    }
                }
                return ms_holder;
            }
        }

        public static void Unload()
        {
            if (ms_ready)
            {
                lock (ms_lockObj)
                {
                    if (ms_ready)
                    {
                        var funcPtr = default(IntPtr);
                        InstanceGetters.TryRemove(ms_key, out funcPtr);
                        if (ms_holder != null)
                        {
                            ms_holder.Dispose();
                            ms_holder = null;
                        }
                        using (InstanceGetters.DisableProcessing())
                            Thread.MemoryBarrier();
                        ms_ready = false;
                    }
                }
            }
        }
    }
}
