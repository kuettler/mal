with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO.Unbounded_IO;
with Interfaces.C.Strings; use type Interfaces.C.Strings.chars_ptr;
with Atoms;
with Core;
with Environments;
with Lists;
with Names;
with Printer;
with Reader;
with Strings; use type Strings.Ptr;
with Types;

procedure Step5_Tco is

   function Read (Source : in String) return Types.Mal_Type
     renames Reader.Read_Str;

   function Eval (Rec_Ast : in Types.Mal_Type;
                  Rec_Env : in Environments.Ptr) return Types.Mal_Type;
   Unable_To_Call : exception;

   function Print (Ast            : in Types.Mal_Type;
                   Print_Readably : in Boolean        := True)
                  return Ada.Strings.Unbounded.Unbounded_String
     renames Printer.Pr_Str;

   function Rep (Source : in String;
                 Env    : in Environments.Ptr)
                return Ada.Strings.Unbounded.Unbounded_String
   is (Print (Eval (Read (Source), Env)))
     with Inline;

   procedure Interactive_Loop (Repl : in Environments.Ptr)
     with Inline;

   --  Convenient when the result of eval is of no interest.
   procedure Discard (Ast : in Types.Mal_Type) is null;

   ----------------------------------------------------------------------

   function Eval (Rec_Ast : in Types.Mal_Type;
                  Rec_Env : in Environments.Ptr) return Types.Mal_Type
   is
      use Types;
      Ast   : Types.Mal_Type   := Rec_Ast;
      Env   : Environments.Ptr := Rec_Env;
      First : Mal_Type;
   begin
   <<Restart>>
      case Ast.Kind is
      when Kind_Nil | Kind_Atom | Kind_Boolean | Kind_Number | Kind_String
        | Kind_Keyword | Kind_Macro | Kind_Function | Kind_Native =>
         return Ast;

      when Kind_Symbol =>
         return Env.Get (Ast.S);

      when Kind_Map =>
         declare
            function F (X : Mal_Type) return Mal_Type is (Eval (X, Env));
         begin
            return (Kind_Map, Atoms.No_Element, Ast.Map.Map (F'Access));
         end;

      when Kind_Vector =>
         return R : constant Mal_Type := (Kind_Vector, Atoms.No_Element,
                                          Lists.Alloc (Ast.L.Length))
         do
            for I in 1 .. Ast.L.Length loop
               R.L.Replace_Element (I, Eval (Ast.L.Element (I), Env));
            end loop;
         end return;

      when Kind_List =>
         if Ast.L.Length = 0 then
            return Ast;
         end if;

         First := Ast.L.Element (1);

         --  Special forms
         if First.Kind = Kind_Symbol then

            if First.S = Names.Def then
               pragma Assert (Ast.L.Length = 3);
               pragma Assert (Ast.L.Element (2).Kind = Kind_Symbol);
               return R : constant Mal_Type := Eval (Ast.L.Element (3), Env) do
                  Env.Set (Ast.L.Element (2).S, R);
               end return;

            elsif First.S = Names.Mal_Do then
               for I in 2 .. Ast.L.Length - 1 loop
                  Discard (Eval (Ast.L.Element (I), Env));
               end loop;
               Ast := Ast.L.Element (Ast.L.Length);
               goto Restart;

            elsif First.S = Names.Fn then
               pragma Assert (Ast.L.Length = 3);
               pragma Assert
                 (Ast.L.Element (2).Kind in Kind_List | Kind_Vector);
               pragma Assert
                 (for all I in 1 .. Ast.L.Element (2).L.Length =>
                    Ast.L.Element (2).L.Element (I).Kind = Kind_Symbol);
               pragma Assert
                 (Ast.L.Element (2).L.Length < 1
                 or else Names.Ampersand /=
                 Ast.L.Element (2).L.Element (Ast.L.Element (2).L.Length).S);
               pragma Assert
                 (for all I in 1 .. Ast.L.Element (2).L.Length - 2 =>
                    Ast.L.Element (2).L.Element (I).S /= Names.Ampersand);
               return (Kind        => Kind_Function,
                       Meta        => Atoms.No_Element,
                       Formals     => Ast.L.Element (2).L,
                       Expression  => Atoms.Alloc (Ast.L.Element (3)),
                       Environment => Env);

            elsif First.S = Names.Mal_If then
               declare
                  pragma Assert (Ast.L.Length in 3 .. 4);
                  Test : constant Mal_Type := Eval (Ast.L.Element (2), Env);
               begin
                  if (case Test.Kind is
                     when Kind_Nil => False,
                     when Kind_Boolean => Test.Boolean_Value,
                     when others => True)
                  then
                     Ast := Ast.L.Element (3);
                     goto Restart;
                  elsif Ast.L.Length = 3 then
                     return (Kind_Nil, Atoms.No_Element);
                  else
                     Ast := Ast.L.Element (4);
                     goto Restart;
                  end if;
               end;

            elsif First.S = Names.Let then
               declare
                  pragma Assert (Ast.L.Length = 3);
                  pragma Assert
                    (Ast.L.Element (2).Kind in Kind_List | Kind_Vector);
                  Bindings : constant Lists.Ptr := Ast.L.Element (2).L;
                  pragma Assert (Bindings.Length mod 2 = 0);
               begin
                  Env.Replace_With_Subenv;
                  Env.Increase_Capacity (Bindings.Length / 2);
                  for I in 1 .. Bindings.Length / 2 loop
                     pragma Assert
                       (Bindings.Element (2 * I - 1).Kind = Kind_Symbol);
                     Env.Set (Bindings.Element (2 * I - 1).S,
                              Eval (Bindings.Element (2 * I), Env));
                  end loop;
                  Ast := Ast.L.Element (3);
                  goto Restart;
               end;
            end if;
         end if;

         --  No special form has been found, attempt to apply the
         --  first element to the rest of the list.
         declare
            Args : Mal_Type_Array (2 .. Ast.L.Length);
         begin
            First := Eval (First, Env);
            for I in Args'Range loop
               Args (I) := Eval (Ast.L.Element (I), Env);
            end loop;
            case First.Kind is
            when Kind_Native =>
               return First.Native.all (Args);
            when Kind_Function =>
               Env := Environments.Alloc (Outer => First.Environment);
               Env.Set_Binds (First.Formals, Args);
               Ast := First.Expression.Deref;
               goto Restart;
            when others =>
               raise Unable_To_Call
                 with Ada.Strings.Unbounded.To_String (Print (First));
            end case;
         end;
      end case;
   end Eval;

   procedure Interactive_Loop (Repl : in Environments.Ptr)
   is

      function Readline (Prompt : in Interfaces.C.char_array)
                        return Interfaces.C.Strings.chars_ptr
        with Import, Convention => C, External_Name => "readline";

      procedure Add_History (Line : in Interfaces.C.Strings.chars_ptr)
        with Import, Convention => C, External_Name => "add_history";

      procedure Free (Line : in Interfaces.C.Strings.chars_ptr)
        with Import, Convention => C, External_Name => "free";

      Prompt : constant Interfaces.C.char_array
        := Interfaces.C.To_C ("user> ");
      C_Line : Interfaces.C.Strings.chars_ptr;
   begin
      loop
         C_Line := Readline (Prompt);
         exit when C_Line = Interfaces.C.Strings.Null_Ptr;
         declare
            Line : constant String := Interfaces.C.Strings.Value (C_Line);
         begin
            if Line /= "" then
               Add_History (C_Line);
            end if;
            Free (C_Line);
            Ada.Text_IO.Unbounded_IO.Put_Line (Rep (Line, Repl));
         exception
            when Reader.Empty_Source =>
               null;
            when E : others =>
               Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (E));
               --  but go on proceeding.
         end;
      end loop;
      Ada.Text_IO.New_Line;
   end Interactive_Loop;

   ----------------------------------------------------------------------

   Repl : constant Environments.Ptr := Environments.Alloc;
begin
   Core.Add_Built_In_Functions (Repl, Eval'Unrestricted_Access);
   Discard (Eval (Read ("(def! not (fn* (a) (if a false true)))"), Repl));

   Interactive_Loop (Repl);
end Step5_Tco;
