
#
# This source file is part of appleseed.
# Visit http://appleseedhq.net/ for additional information and resources.
#
# This software is released under the MIT license.
#
# Copyright (c) 2013 Franz Beaune, Joel Daniels, Esteban Tovagliari.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

import bpy, bl_ui, bl_operators
import math, mathutils
import os, subprocess, time
from shutil   import copyfile
from datetime import datetime
from .        import util
import sys

if sys.platform == 'win32':
    from . import mesh_writer
else:
    from . import mesh_writer_unix as mesh_writer

identity_matrix = mathutils.Matrix(((1.0, 0.0, 0.0, 0.0),
                                    (0.0, 0.0, -1.0, 0.0),
                                    (0.0, 1.0, 0.0, 0.0),
                                    (0.0, 0.0, 0.0, 1.0)))
        
def is_black( color):
    return color[0] == 0.0 and color[1] == 0.0 and color[2] == 0.0

def add( color1, color2):
    return [ color1[0] + color2[0], color1[1] + color2[1], color1[2] + color2[2] ]

def mul( color, multiplier):
    return [ color[0] * multiplier, color[1] * multiplier, color[2] * multiplier ]

def object_enumerator( type):
    matches = []
    for object in bpy.data.objects:
        if object.type == type:
            matches.append(( object.name, object.name, ""))
    return matches

    
class write_project_file( object):
    # Primary export function.
    def export(self, scene, file_path):
        '''
        Write the .appleseed project file for rendering.
        '''
        if scene is None:
            self.__error("No scene to export.")
            return

        # Transformation matrix applied to all entities of the scene.
        self._global_scale = 1
        self._global_matrix = mathutils.Matrix.Scale(self._global_scale, 4)
        
        # Store textures as they are exported.
        self._textures_set = set()    
        
        # Collect objects with motion blur.
        self._def_mblur_obs = {ob.name: '' for ob in scene.objects if ob.appleseed.mblur_enable and ob.appleseed.mblur_type == 'deformation'}
        self._selected_objects = [ ob.name for ob in scene.objects if ob.select]
        self._dupli_objects = []
        
        # Render layer rules. Pattern is the object name.
        # Object name - > render layer.
        self._rules = {}
        self._rule_index = 1
        
        # Blender material -> front material name, back material name.
        self._emitted_materials = {}

        # Object name -> instance count.
        self._instance_count = {}
        self._assembly_count = {}
        self._assembly_instance_count = {}
        
        # Object name -> (material index, mesh name).
        self._mesh_parts = {}

        # Instanced particle objects.
        # Write mesh files but do not write to appleseed file.
        self._no_export = {ob.name for ob in util.get_all_psysobs()}

        self.__info("")
        self.__info("Starting export of scene '{0}' to {1}...".format(scene.name, file_path))

        start_time = datetime.now()

        try:
            with open(file_path, "w") as self._output_file:
                self._indent = 0
                self.__emit_file_header()
                self.__emit_project(scene)
        except IOError:
            self.__error("Could not write to {0}.".format(file_path))
            return

        elapsed_time = datetime.now() - start_time

        self.__info("Finished exporting in {0}".format(elapsed_time))

    #----------------------------------------------------------------------------------------------
    # Export the project.
    #----------------------------------------------------------------------------------------------
    
    def __get_selected_camera( self, scene):
        if scene.camera is not None and scene.camera.name in bpy.data.objects:
            return scene.camera
        else: return None

    def __emit_file_header(self):
        self.__emit_line( "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        self.__emit_line( "<!-- File generated by {0} {1}. -->".format( "render_appleseed", util.version))

    def __emit_project( self, scene):
        self.__open_element( "project")
        self.__emit_scene( scene)
        self.__emit_rules( scene)
        self.__emit_output( scene)
        self.__emit_configurations( scene)
        self.__close_element( "project")

    #----------------------------------------------------------------------------------------------
    # Scene.
    #----------------------------------------------------------------------------------------------

    def __emit_scene(self, scene):
        self.__open_element( "scene")
        self.__emit_camera( scene)
        self.__emit_environment( scene)
        self.__emit_assembly( scene)
        self.__emit_assembly_instance( scene)
        self.__close_element( "scene")

    #--------------------------------
    def __emit_assembly(self, scene):
        '''
        Write the scene assembly.
        '''
        self.__open_element( 'assembly name="%s"' % scene.name)
        self.__emit_physical_surface_shader_element()
        self.__emit_default_material( scene)
        self.__emit_objects( scene)
        self.__close_element( "assembly")

    #--------------------------------
    def __emit_assembly_instance( self, scene, obj = None):
        '''
        Write a scene assembly instance,
        or write an assembly instance for an object with transformation motion blur.
        '''
        asr_scn = scene.appleseed
        shutter_open = asr_scn.shutter_open if asr_scn.mblur_enable else 0
        shutter_close = asr_scn.shutter_close if asr_scn.mblur_enable else 1
        if obj is not None:
            # Write object assembly for an object with motion blur.
            obj_name = obj.name
            self.__open_element( 'assembly_instance name="%s_instance" assembly="%s"' % (obj_name, obj_name))
            current_frame = scene.frame_current

            # Advance to shutter open, collect matrix.
            scene.frame_set( current_frame, subframe = shutter_open)
            instance_matrix = self._global_matrix * obj.matrix_world

            # Advance to next frame, collect matrix.
            scene.frame_set( current_frame, subframe = shutter_close)
            next_matrix = self._global_matrix * obj.matrix_world

            # Reset timeline.
            scene.frame_set( current_frame)

            self.__emit_transform_element( instance_matrix, 0)
            self.__emit_transform_element( next_matrix, 1)
            self.__close_element( "assembly_instance")
        else:
            # No object, write an assembly for the whole scene.
            self.__open_element( 'assembly_instance name="%s_instance" assembly="%s"' % (scene.name, scene.name))
            self.__close_element( "assembly_instance")

    #--------------------------------
    def __emit_object_assembly( self, scene, object):
        ''' 
        Write an assembly for an object with transformation motion blur.
        '''
        object_name = object.name
        self.__open_element( 'assembly name="%s"' % object_name)
        self.__emit_physical_surface_shader_element()
        self.__emit_default_material( scene)
        self.__emit_geometric_object( scene, object, True)
        self.__close_element( "assembly")

    #--------------------------------
    def __emit_dupli_assembly( self, scene, object, matrices):
        ''' 
        Write an assembly for a dupli/particle with transformation motion blur.
        '''
        object_name = object.name
        # Figure out the instance number of this assembly instance.
        if object_name in self._assembly_count:
            instance_index = self._assembly_count[object_name] + 1
        else:
            instance_index = 0
        self._assembly_count[object_name] = instance_index

        assembly_name = "%s_%d" % ( object_name, instance_index)
        self.__open_element( 'assembly name="%s"' % assembly_name)
        self.__emit_physical_surface_shader_element()
        self.__emit_default_material( scene)
        self.__emit_dupli_object( scene, object, matrices, True, new_assembly = True)
        self.__close_element( "assembly")
        # Emit an instance of the dupli object assembly.
        self.__emit_dupli_assembly_instance( scene, assembly_name, matrices)
        
    #--------------------------------     
    def __emit_dupli_assembly_instance( self, scene, assembly_name, matrices):
        '''
        Write an instance of the dupli object assembly (for duplis/particles with motion blur).
        '''
        asr_scn = scene.appleseed
        # Figure out the instance number of this assembly instance.
        if assembly_name in self._assembly_instance_count:
            instance_index = self._assembly_instance_count[assembly_name] + 1
        else:
            instance_index = 0
        self._assembly_instance_count[assembly_name] = instance_index
        
        self.__open_element( 'assembly_instance name="%s.instance_%d" assembly="%s"' % (assembly_name, instance_index, assembly_name))

        instance_matrix = self._global_matrix * matrices[0].copy()
        next_matrix = self._global_matrix * matrices[1].copy()
        
        # Emit transformation matrices with their respective times.
        self.__emit_transform_element( instance_matrix, 0)
        self.__emit_transform_element( next_matrix, 1)
        self.__close_element( "assembly_instance")

    #--------------------------------
    def __emit_objects( self, scene):
        '''
        Emit the objects in the scene.
        '''
        for object in scene.objects:
            if util.do_export( object, scene):  # Skip objects marked as non-renderable.
                if object.type == 'LAMP':
                    self.__emit_light( scene, object)
                else:
                    self._dupli_objects.clear()
                    if util.ob_mblur_enabled( object, scene):
                        if object.is_duplicator and object.dupli_type in {'VERTS', 'FACES'}:
                            # Motion blur enabled on a dupli parent 
                            self._dupli_objects = util.get_instances( object, scene)
                            for dupli_obj in self._dupli_objects:
                                # Each "dupli" in dupli_objects is a nested list: [dupli.object, [object.matrix1, object.matrix2]]
                                inst_mats = dupli_obj[1]
                                self.__emit_dupli_assembly( scene, dupli_obj[0], inst_mats )
                         
                        elif util.is_psys_emitter( object):
                            # Motion blur enabled on a particle system emitter.
                            particle_obs = util.get_psys_instances( object, scene)
                            for ob in particle_obs:             # each 'ob' is a particle, as dict key
                                                                # The value is a list: dupli.object and another list of two matrices
                                dupli_obj = particle_obs[ob][0]     # The dupli.object
                                inst_mats = particle_obs[ob][1]     # The list of matrices
                                self.__emit_dupli_assembly( scene, dupli_obj, inst_mats)
                                 
                            if util.render_emitter( object):
                                self.__emit_object_assembly( scene, object)
                                self.__emit_assembly_instance( scene, obj = object)
                        else:
                            # No duplis, no particle systems.
                            self.__emit_object_assembly( scene, object)
                            self.__emit_assembly_instance( scene, obj = object)
                    else:
                        # No motion blur enabled.
                        self.__emit_geometric_object( scene, object, False)

    #----------------------------------------------------------------------------------------------
    # Geometry.
    #----------------------------------------------------------------------------------------------

    def __emit_geometric_object(self, scene, object, ob_mblur = False):
        '''
        Get scene objects and instances for emitting.
        Only emit dupli- objects if the object doesn't have moblur enabled.
        Dupli- objects with object motion blur are handled separately.
        '''
        if not ob_mblur:
            self._dupli_objects.clear()

            if object.parent and object.parent.dupli_type in { 'VERTS', 'FACES' }:  
                # todo: what about dupli type 'GROUP'?
                return

            if object.is_duplicator:
                self._dupli_objects.extend( util.get_instances( object, scene))
                if util.is_psys_emitter( object) and util.render_emitter( object):
                    self._dupli_objects.append( [object, object.matrix_world])
                    
            # No duplis or particle systems.
            else:
                self._dupli_objects = [ (object, object.matrix_world) ]
            
        # Motion blur is enabled
        else:
            self._dupli_objects = [ (object, identity_matrix)]
            
        # Emit the dupli objects.
        for dupli_object in self._dupli_objects:
            self.__emit_dupli_object( scene, dupli_object[0], dupli_object[1], ob_mblur)

    #--------------------------------
    def __emit_dupli_object(self, scene, object, object_matrix, ob_mblur, new_assembly = False):
        '''
        Emit objects / dupli objects.
        '''
        asr_scn = scene.appleseed
        shutter_open = asr_scn.shutter_open if asr_scn.mblur_enable else 0
        current_frame = scene.frame_current
        # Emit the mesh object (and write it to disk) only the first time it is encountered.
        # If it's a new assembly (for dupli motion blur), only emit the object without tesselating mesh.
        export_mesh = True
        if new_assembly or object.name not in self._instance_count:
            try:
                # Export hair as curves, if enabled in settings.
                export_hair = scene.appleseed.export_hair and util.has_hairsys( object)
                if export_hair:
                    if not util.render_emitter( object):
                        export_mesh = False
                        
                #-----------------------------------------------------------------------
                # If deformation motion blur is enabled, write deformation mesh to disk.
                if util.def_mblur_enabled( object, scene):
                    scene.frame_set( current_frame, subframe = asr_scn.shutter_close)
                    # Tessellate the object at the next frame to export mesh for deformation motion blur.
                    if export_mesh:
                        def_mesh = object.to_mesh( scene, True, 'RENDER', calc_tessface = True)
                        mesh_faces = def_mesh.tessfaces
                        mesh_uvtex = def_mesh.tessface_uv_textures
                        # Write the deformation motion blur mesh to disk.
                        self.__emit_def_mesh_object( scene, object, def_mesh, mesh_faces, mesh_uvtex)
                        # Delete the mesh.
                        bpy.data.meshes.remove( def_mesh)
                        
                    if export_hair:
                        for mod in object.modifiers:
                            if mod.type == 'PARTICLE_SYSTEM' and mod.show_render:
                                psys = mod.particle_system
                                if psys.settings.type == 'HAIR' and psys.settings.render_type == 'PATH':
                                    mat_index = psys.settings.material - 1
                                    material = object.material_slots[mat_index].name
                                    # Write the deformation motion blur hair mesh to disk.
                                    self.__emit_def_curves_object( scene, object, psys.name)

                    # Reset the timeline to current frame
                    scene.frame_set( current_frame) 
                #-----------------------------------------------------------------------
                
                # Tessellate the object at shutter open.
                scene.frame_set( current_frame, subframe = shutter_open)
                if export_mesh:
                    mesh = object.to_mesh(scene, True, 'RENDER', calc_tessface = True)
                    mesh_faces = mesh.tessfaces
                    mesh_uvtex = mesh.tessface_uv_textures
                    # Write the geometry to disk and emit a mesh object element.
                    self._mesh_parts[object.name] = self.__emit_mesh_object(scene, object, mesh, mesh_faces, mesh_uvtex, new_assembly)
                    # Delete the mesh
                    bpy.data.meshes.remove( mesh)
                    
                if export_hair:
                    for mod in object.modifiers:
                        if mod.type == 'PARTICLE_SYSTEM' and mod.show_render:
                            psys = mod.particle_system
                            if psys.settings.type == 'HAIR' and psys.settings.render_type == 'PATH':
                                mat_index = psys.settings.material - 1
                                material = object.material_slots[mat_index].name
                                # Write the curves to disk and emit a curves object element.
                                self._mesh_parts["_".join( [object.name, psys.name])] = self.__emit_curves_object( scene, object, psys, new_assembly)
                                
                                # Emit the curves object instance.
                                self.__emit_mesh_object_instance( scene, object, self._global_matrix, new_assembly, hair = True, hair_material = material, psys_name = psys.name)

                # Reset timeline.
                scene.frame_set( current_frame)

            except RuntimeError:
                self.__info("Skipping object '{0}' of type '{1}' because it could not be converted to a mesh.".format(object.name, object.type))
                return
                
        # Emit the object instance.
        if export_mesh:
            self.__emit_mesh_object_instance( scene, object, object_matrix, new_assembly)

    #--------------------------------
    def __emit_curves_object( self, scene, object, psys, new_assembly = False):
        '''
        Emit the curves object element and write to disk.
        Return mesh parts to self._mesh_parts["_".join( [object.name, psys.name])]
        '''
        curves_name = "_".join( [object.name, psys.name])
        curves_filename = curves_name + ".curves"

        meshes_path = os.path.join( util.realpath( scene.appleseed.project_path), "meshes")
        export_curves = False
        if scene.appleseed.generate_mesh_files:
            curves_filepath = os.path.join( meshes_path, curves_filename)
            if not os.path.exists( meshes_path):
                os.mkdir( meshes_path)
            if scene.appleseed.export_mode == 'all':
                export_curves = True
            if scene.appleseed.export_mode == 'partial' and not os.path.exists( curves_filepath):
                export_curves = True
            if scene.appleseed.export_mode == 'selected' and object.name in self._selected_objects:
                export_curves = True
            if new_assembly and curves_name in self._instance_count:
                export_curves = False
            if export_curves:
                # Export curves file to disk.
                self.__progress("Exporting particle system '{0}' to {1}...".format( psys.name, curves_filename))
                try:
                    mesh_writer.write_curves_to_disk( object, scene, psys, curves_filepath)
                except IOError:
                    self.__error("While exporting particle system '{0}': could not write to {1}, skipping particle system.".format( psys.name, curves_filepath))
                    return []

        self.__emit_curves_element( curves_name, curves_filename, object, scene)
        # Hard code one mesh part for now, since particle systems aren't split into materials.
        return [(0, "part_0")]
        
        
    #--------------------------------
    def __emit_mesh_object( self, scene, object, mesh, mesh_faces, mesh_uvtex, new_assembly):
        '''
        Emit the mesh object element and write to disk.
        Return mesh parts to self._mesh_parts[object.name]
        '''
        if len( mesh_faces) == 0:
            self.__info("Skipping object '{0}' since it has no faces once converted to a mesh.".format(object.name))
            return []

        object_name = object.name
            
        mesh_filename = object_name + ".obj"
        meshes_path = os.path.join( util.realpath( scene.appleseed.project_path), "meshes")
        export_mesh = False
        if scene.appleseed.generate_mesh_files:
            mesh_filepath = os.path.join( meshes_path, mesh_filename)
            if not os.path.exists( meshes_path):
                os.mkdir( meshes_path)
            if scene.appleseed.export_mode == 'all':
                export_mesh = True
            if scene.appleseed.export_mode == 'partial' and not os.path.exists( mesh_filepath):
                export_mesh = True
            if scene.appleseed.export_mode == 'selected' and object.name in self._selected_objects:
                export_mesh = True
            if new_assembly and object.name in self._instance_count:
                export_mesh = False
            if export_mesh:
                # Export the mesh to disk.
                self.__progress("Exporting object '{0}' to {1}...".format( object_name, mesh_filename))
                try:
                    mesh_parts = mesh_writer.write_mesh_to_disk( object, scene, mesh, mesh_filepath)
                except IOError:
                    self.__error("While exporting object '{0}': could not write to {1}, skipping this object.".format(object.name, mesh_filepath))
                    return []
                    
        if scene.appleseed.generate_mesh_files == False or export_mesh == False:
            # Build a list of mesh parts just as if we had exported the mesh to disk.
            material_indices = set()
            for face in mesh_faces:
                material_indices.add( face.material_index)
            mesh_parts = map(lambda material_index : ( material_index, "part_%d" % material_index), material_indices)
            
        # Emit object.
        self.__emit_object_element( object_name, mesh_filename, object, scene)

        return mesh_parts

    #--------------------------------
    def __emit_object_element( self, object_name, mesh_file, object, scene):
        '''
        Emit an object element to the project file.
        '''
        mesh_filename = "meshes" + os.path.sep + mesh_file
        self.__open_element('object name="' + object_name + '" model="mesh_object"')
        if util.def_mblur_enabled( object, scene):
            self.__open_element('parameters name="filename"')
            self.__emit_parameter("0", mesh_filename)
            self.__emit_parameter("1", "meshes" + os.path.sep + self._def_mblur_obs[object_name])
            self.__close_element("parameters")
        else:
            self.__emit_parameter("filename", mesh_filename)
        self.__close_element("object")

    #--------------------------------
    def __emit_curves_element( self, curves_name, curves_file, object, scene):
        '''
        Emit a curves object element to the project file.
        '''
        curves_filename = "meshes" + os.path.sep + curves_file
        self.__open_element('object name="' + curves_name + '" model="curve_object"')
        if util.def_mblur_enabled( object, scene):
            self.__open_element('parameters name="filepath"')
            self.__emit_parameter("0", curves_filename)
            self.__emit_parameter("1", "meshes" + os.path.sep + self._def_mblur_obs[curves_name])
            self.__close_element("parameters")
        else:
            self.__emit_parameter("filepath", curves_filename)
        self.__close_element("object")
        
    # --------------------------------------------------
    # Emit object mesh for deformation mblur evaluation.
    # --------------------------------------------------
    def __emit_def_mesh_object( self, scene, object, mesh, mesh_faces, mesh_uvtex):
        '''
        Emit a deformation mesh object and write to disk.
        '''
        if len( mesh_faces) == 0:
            self.__info("Skipping object '{0}' since it has no faces once converted to a mesh.".format(object.name))
            return []

        object_name = object.name            
        mesh_filename = object_name + "_deform.obj"

        self._def_mblur_obs[object_name] = mesh_filename

        meshes_path = os.path.join( util.realpath( scene.appleseed.project_path), "meshes")
        export_mesh = False
        if scene.appleseed.generate_mesh_files:
            mesh_filepath = os.path.join( meshes_path, mesh_filename)
            if not os.path.exists( meshes_path):
                os.mkdir( meshes_path)
            if scene.appleseed.export_mode == 'all':
                export_mesh = True
            if scene.appleseed.export_mode == 'partial' and not os.path.exists( mesh_filepath):
                export_mesh = True
            if scene.appleseed.export_mode == 'selected' and object.name in self._selected_objects:
                export_mesh = True
            if export_mesh:
                # Export the mesh to disk.
                self.__progress("Exporting object '{0}' to {1}...".format( object_name, mesh_filename))
                try:
                    mesh_writer.write_mesh_to_disk( object, scene, mesh, mesh_filepath)
                except IOError:
                    self.__error("While exporting object '{0}': could not write to {1}, skipping this object.".format(object.name, mesh_filepath))

    # --------------------------------------------------
    # Emit curves object for deformation mblur evaluation.
    # --------------------------------------------------
    def __emit_def_curves_object( self, scene, object, psys):
        '''
        Emit a curves deformation mesh object and write to disk.
        '''

        curves_name = "_".join( [object.name, psys.name])
        curves_filename = curves_name + "_deform.curves"

        self._def_mblur_obs[curves_name] = curves_filename

        meshes_path = os.path.join( util.realpath( scene.appleseed.project_path), "meshes")
        export_curves = False
        if scene.appleseed.generate_mesh_files:
            curves_filepath = os.path.join( meshes_path, curves_filename)
            if not os.path.exists( meshes_path):
                os.mkdir( meshes_path)
            if scene.appleseed.export_mode == 'all':
                export_curves = True
            if scene.appleseed.export_mode == 'partial' and not os.path.exists( curves_filepath):
                export_curves = True
            if scene.appleseed.export_mode == 'selected' and object.name in self._selected_objects:
                export_curves = True
            if export_curves:
                # Export curves file to disk.
                self.__progress("Exporting particle system '{0}' to {1}...".format( psys.name, curves_filename))
                try:
                    mesh_writer.write_curves_to_disk( object, scene, psys, curves_filepath)
                except IOError:
                    self.__error("While exporting particle system '{0}': could not write to {1}, skipping particle system.".format( psys.name, curves_filepath))
                    
    #---------------------------
    # Emit mesh object instance.
    #---------------------------
    def __emit_mesh_object_instance( self, scene, object, object_matrix, new_assembly, hair = False, hair_material = None, psys_name = None):
        '''
        Calls __emit_object_instance_element to emit an object instance.
        '''
        object_name = "_".join( [object.name, psys_name]) if hair else object.name
        if new_assembly:
            object_matrix = self._global_matrix * identity_matrix 
        else:
            object_matrix = self._global_matrix * object_matrix

        if hair:
            util.debug( object_name, object_matrix)
        # Emit BSDFs and materials if they are encountered for the first time.
        for material_slot_index, material_slot in enumerate(object.material_slots):
            material = material_slot.material
            if material is None:
                self.__warning("While exporting instance of object '{0}': material slot #{1} has no material.".format(object.name, material_slot_index))
                continue
            if new_assembly or material not in self._emitted_materials:
                # Need to emit material again if it's in a separate assembly.
                self._emitted_materials[material] = self.__emit_material(material, scene)

        # Figure out the instance number of this object.
        if not new_assembly and object_name in self._instance_count:
            instance_index = self._instance_count[object_name] + 1
        else:
            instance_index = 0
        self._instance_count[object_name] = instance_index

        # Emit object parts instances.
        for (material_index, mesh_name) in self._mesh_parts[object_name]:
            # A hack for now:
            # Is there a bug in how this is being interpreted by appleseed?
            if not hair:
                part_name = "{0}.{1}".format(object_name, mesh_name)
            else:
                part_name = object_name
            instance_name = "{0}.instance_{1}".format(part_name, instance_index)
            front_material_name = "__default_material"
            back_material_name = "__default_material"
            if material_index < len(object.material_slots):
                if not hair:
                    material = object.material_slots[material_index].material
                else:
                    material = bpy.data.materials[hair_material]
                if material:
                    front_material_name, back_material_name = self._emitted_materials[material]

            if hair:
                util.debug( object_name, object_matrix)
            self.__emit_object_instance_element(part_name, instance_name, object_matrix, front_material_name, back_material_name, object, scene)

    #---------------------------------------------
    # Emit an object instance to the project file.
    #---------------------------------------------
    def __emit_object_instance_element( self, object_name, instance_name, instance_matrix, front_material_name, back_material_name, object, scene):
        '''
        Emit an object instance element to the project file.
        '''
        self.__open_element('object_instance name="{0}" object="{1}"'.format(instance_name, object_name))
        if util.ob_mblur_enabled( object, scene):
            self.__emit_transform_element( identity_matrix, None)
        else:
            self.__emit_transform_element( instance_matrix, None)
        self.__emit_line('<assign_material slot="0" side="front" material="{0}" />'.format(front_material_name))
        self.__emit_line('<assign_material slot="0" side="back" material="{0}" />'.format(back_material_name))
        if bool(object.appleseed.render_layer):
            self._rules[ object.name] = object.appleseed.render_layer
        self.__close_element("object_instance")


    #----------------------------------------------------------------------------------------------
    # Materials.
    #----------------------------------------------------------------------------------------------

    def __is_light_emitting_material( self, asr_mat, scene, material_node = None):
        if material_node is not None:
            if material_node.inputs["Emission Strength"].socket_value > 0.0 or material_node.inputs["Emission Strength"].is_linked:
                return scene.appleseed.export_emitting_obj_as_lights
        else:
            return asr_mat.use_light_emission and scene.appleseed.export_emitting_obj_as_lights

    def __is_node_material( self, asr_mat):
        if asr_mat.node_tree != "" and asr_mat.node_output != "":
            node = bpy.data.node_groups[ asr_mat.node_tree].nodes[ asr_mat.node_output]
            return node.node_type == 'material' 

    def __emit_physical_surface_shader_element(self):
        self.__emit_line('<surface_shader name="physical_surface_shader" model="physical_surface_shader" />')

    def __emit_default_material(self, scene):
        self.__emit_solid_linear_rgb_color_element("__default_material_bsdf_reflectance", [ 0.8 ], 1.0)

        self.__open_element('bsdf name="__default_material_bsdf" model="lambertian_brdf"')
        self.__emit_parameter("reflectance", "__default_material_bsdf_reflectance")
        self.__close_element("bsdf")

        self.__emit_material_element("__default_material", "__default_material_bsdf", "", "physical_surface_shader", scene, "")

    #-------------------------------------------
    # Write the material.
    #-------------------------------------------
    def __emit_material( self, material, scene):
        asr_mat = material.appleseed
        asr_node_tree = asr_mat.node_tree
        use_nodes = self.__is_node_material( asr_mat)
        layers = asr_mat.layers

        material_node = None
        node_list = None
        front_material_name = ""

        # If using nodes.
        if use_nodes:
            # Get all nodes. If specular btdf or diffuse btdf in the list, emit back material as well.
            material_node = bpy.data.node_groups[ asr_node_tree].nodes[ asr_mat.node_output]
            node_list = material_node.traverse_tree()
            for node in node_list:
                if node.node_type == "specular_btdf":
                    front_material_name = material.name + "_front"
                    back_material_name = material.name + "_back"
                    self.__emit_front_material(material, front_material_name, scene, layers, material_node, node_list)
                    self.__emit_back_material(material, back_material_name, scene, layers, material_node, node_list)
                    break
        else:
            # Need to iterate through layers only once, to find out if we have any specular btdfs.
            for layer in layers:
                if layer.bsdf_type == "specular_btdf":
                    front_material_name = material.name + "_front"
                    back_material_name = material.name + "_back"
                    self.__emit_front_material(material, front_material_name, scene, layers)
                    self.__emit_back_material(material, back_material_name, scene, layers)
                    break
            
        # If we didn't find any, then we're only exporting front material.
        if front_material_name == "":
            front_material_name = material.name
            self.__emit_front_material(material, front_material_name, scene, layers, material_node, node_list)
            if self.__is_light_emitting_material( asr_mat, scene, material_node):
                # Assign the default material to the back face if the front face emits light,
                # as we don't want mesh lights to emit from both faces.
                back_material_name = "__default_material"
            else: 
                back_material_name = front_material_name

        return front_material_name, back_material_name

    # Emit front material.
    def __emit_front_material(self, material, material_name, scene, layers, material_node = None, node_list = None):
        # material_name here is material.name + "_front"    
        bsdf_name = self.__emit_front_material_bsdf_tree( material, material_name, scene, layers, material_node, node_list)

        if self.__is_light_emitting_material( material.appleseed, scene, material_node):
            edf_name = "{0}_edf".format( material_name)
            self.__emit_edf( material, edf_name, scene, material_node)
        else: edf_name = ""

        self.__emit_material_element(material_name, bsdf_name, edf_name, "physical_surface_shader", scene, material, material_node)

    # Emit back material.
    def __emit_back_material(self, material, material_name, scene, layers, material_node = None, node_list = None):
        # material_name here is material.name + "_back" 
        bsdf_name = self.__emit_back_material_bsdf_tree(material, material_name, scene, layers, material_node, node_list)
        
        self.__emit_material_element(material_name, bsdf_name, "", "physical_surface_shader", scene, material, material_node)

    #--------------------------------
    # Write front material BSDF tree.
    #--------------------------------
    def __emit_front_material_bsdf_tree(self, material, material_name, scene, layers, material_node = None, node_list = None):
        '''
        Emit the front material's BSDF tree and return the last BSDF name to the calling function (__emit_front_material).
        '''
        # material_name here is material.name + "_front" 
        bsdfs = []
        asr_mat = material.appleseed

        # If using nodes.
        if material_node is not None:
            if not material_node.inputs[0].is_linked:
                default_bsdf_name = "__default_material_bsdf"
                return default_bsdf_name
            
            for node in node_list:
                if node.node_type not in {'texture', 'normal'}:
                    bsdf_name = material_name + node.get_node_name()
                if node.node_type == 'ashikhmin':
                    self.__emit_ashikhmin_brdf( material, bsdf_name, 'front', None, node)
                if node.node_type == 'bsdf_blend':
                    self.__emit_bsdf_blend( bsdf_name, material_name, node)
                if node.node_type == 'diffuse_btdf':
                    self.__emit_diffuse_btdf( material, bsdf_name, 'front', None, node)
                if node.node_type == 'disney':
                    self.__emit_disney_brdf( material, bsdf_name, 'front', None, node)
                if node.node_type == 'kelemen':
                    self.__emit_kelemen_brdf( material, bsdf_name, 'front', None, node)
                if node.node_type == 'lambertian':
                    self.__emit_lambertian_brdf( material, bsdf_name, 'front', None, node)
                if node.node_type == 'microfacet':
                    self.__emit_microfacet_brdf( material, bsdf_name, 'front', None, node)
                if node.node_type == 'orennayar':
                    self.__emit_orennayar_brdf( material, bsdf_name, 'front', None, node)
                if node.node_type == 'specular_btdf':
                    self.__emit_specular_btdf( material, bsdf_name, scene, 'front', None, node)
                if node.node_type == 'specular_brdf':
                    self.__emit_specular_brdf( material, bsdf_name, 'front', None, node)
                if node.node_type == 'texture':
                    self.__emit_texture( None, False, scene, node, material_name)
            return bsdf_name
            
        else:
            # Iterate through layers and export their types, append names and weights to bsdfs list
            if len(layers) == 0:
                default_bsdf_name = "__default_material_bsdf"
                return default_bsdf_name
            else:
                for layer in layers:
                    # Spec BTDF
                    if layer.bsdf_type == "specular_btdf":
                        transp_bsdf_name = "{0}|{1}".format( material_name, layer.name)
                        self.__emit_specular_btdf( material, transp_bsdf_name, scene, 'front', layer)
                        # Layer mask textures.
                        if layer.spec_btdf_use_tex and layer.spec_btdf_mix_tex != '':   
                            bsdfs.append( [ transp_bsdf_name, layer.spec_btdf_mix_tex + "_inst"])
                            mix_tex_name = layer.spec_btdf_mix_tex + "_inst"
                            if mix_tex_name not in self._textures_set:
                                self.__emit_texture( bpy.data.textures[ layer.spec_btdf_mix_tex], False, scene)
                                self._textures_set.add( mix_tex_name)
                        else:
                            bsdfs.append([ transp_bsdf_name, layer.spec_btdf_weight ])

                    # Spec BRDF
                    elif layer.bsdf_type == "specular_brdf":
                        mirror_bsdf_name = "{0}|{1}".format(material_name, layer.name)
                        self.__emit_specular_brdf(material, mirror_bsdf_name, scene, layer)
                        # Layer mask textures.
                        if layer.specular_use_tex and layer.specular_mix_tex != '':   
                            bsdfs.append( [ mirror_bsdf_name, layer.specular_mix_tex + "_inst"])
                            mix_tex_name = layer.specular_mix_tex + "_inst"
                            if mix_tex_name not in self._textures_set:
                                self.__emit_texture( bpy.data.textures[ layer.specular_mix_tex], False, scene)
                                self._textures_set.add( mix_tex_name)
                        else:
                            bsdfs.append([ mirror_bsdf_name, layer.specular_weight ])

                    # Diffuse BTDF
                    elif layer.bsdf_type == "diffuse_btdf":   
                        dt_bsdf_name = "{0}|{1}".format(material_name, layer.name)
                        self.__emit_diffuse_btdf(material, dt_bsdf_name, scene, layer)
                        # Layer mask textures.
                        if layer.transmittance_use_tex and layer.transmittance_mix_tex != '':   
                            bsdfs.append( [ dt_bsdf_name, layer.transmittance_mix_tex + "_inst"])
                            mix_tex_name = layer.transmittance_mix_tex + "_inst"

                            if mix_tex_name not in self._textures_set:
                                self.__emit_texture( bpy.data.textures[ layer.transmittance_mix_tex], False, scene)
                                self._textures_set.add( mix_tex_name)
                        else:
                            bsdfs.append([ dt_bsdf_name, layer.transmittance_weight])

                    # Disney
                    elif layer.bsdf_type == "disney_brdf":
                        disney_bsdf_name = "{0}|{1}".format(material_name, layer.name)
                        self.__emit_disney_brdf(material, disney_bsdf_name, scene, layer = layer)
                        # Layer mask textures.
                        if layer.disney_use_tex and layer.disney_mix_tex != '':   
                            bsdfs.append( [ disney_bsdf_name, layer.disney_mix_tex + "_inst"])
                            mix_tex_name = layer.disney_mix_tex + "_inst"
                            if mix_tex_name not in self._textures_set:
                                self.__emit_texture( bpy.data.textures[ layer.disney_mix_tex], False, scene)
                                self._textures_set.add( mix_tex_name)
                        else:
                            bsdfs.append([ disney_bsdf_name, layer.disney_weight])
                            
                    # Lambertian
                    elif layer.bsdf_type == "lambertian_brdf":
                        lbrt_bsdf_name = "{0}|{1}".format(material_name, layer.name)
                        self.__emit_lambertian_brdf(material, lbrt_bsdf_name, scene, layer)
                        # Layer mask textures.
                        if layer.lambertian_use_tex and layer.lambertian_mix_tex != '':   
                            bsdfs.append( [ lbrt_bsdf_name, layer.lambertian_mix_tex + "_inst"])
                            mix_tex_name = layer.lambertian_mix_tex + "_inst"
                            if mix_tex_name not in self._textures_set:
                                self.__emit_texture( bpy.data.textures[ layer.lambertian_mix_tex], False, scene)
                                self._textures_set.add( mix_tex_name)
                        else:
                            bsdfs.append([ lbrt_bsdf_name, layer.lambertian_weight])

                    # Oren-Nayar
                    elif layer.bsdf_type == "orennayar_brdf":
                        lbrt_bsdf_name = "{0}|{1}".format(material_name, layer.name)
                        self.__emit_orennayar_brdf(material, lbrt_bsdf_name, scene, layer)
                        # Layer mask textures.
                        if layer.orennayar_use_tex and layer.orennayar_mix_tex != '':   
                            bsdfs.append( [ lbrt_bsdf_name, layer.orennayar_mix_tex + "_inst"])
                            mix_tex_name = layer.orennayar_mix_tex + "_inst"
                            if mix_tex_name not in self._textures_set:
                                self.__emit_texture( bpy.data.textures[ layer.orennayar_mix_tex], False, scene)
                                self._textures_set.add( mix_tex_name)
                        else:
                            bsdfs.append([ lbrt_bsdf_name, layer.orennayar_weight])

                    # Ashikhmin
                    elif layer.bsdf_type == "ashikhmin_brdf":
                        ashk_bsdf_name = "{0}|{1}".format(material_name, layer.name)
                        self.__emit_ashikhmin_brdf(material, ashk_bsdf_name, scene, layer)
                        # Layer mask textures.
                        if layer.ashikhmin_use_tex and layer.ashikhmin_mix_tex != '':   
                            bsdfs.append( [ ashk_bsdf_name, layer.ashikhmin_mix_tex + "_inst"])
                            mix_tex_name = layer.ashikhmin_mix_tex + "_inst"
                            if mix_tex_name not in self._textures_set:
                                self.__emit_texture( bpy.data.textures[ layer.ashikhmin_mix_tex], False, scene)
                                self._textures_set.add( mix_tex_name)
                        else:
                            bsdfs.append([ ashk_bsdf_name, layer.ashikhmin_weight ])

                    # Microfacet
                    elif layer.bsdf_type == "microfacet_brdf":
                        mfacet_bsdf_name = "{0}|{1}".format(material_name, layer.name)
                        self.__emit_microfacet_brdf(material, mfacet_bsdf_name, scene, layer)
                        # Layer mask textures.
                        if layer.microfacet_use_tex and layer.microfacet_mix_tex != '':   
                            bsdfs.append( [ mfacet_bsdf_name, layer.microfacet_mix_tex + "_inst"])
                            mix_tex_name = layer.microfacet_mix_tex + "_inst"
                            if mix_tex_name not in self._textures_set:
                                self.__emit_texture( bpy.data.textures[ layer.microfacet_mix_tex], False, scene)
                                self._textures_set.add( mix_tex_name)
                        else:
                            bsdfs.append([ mfacet_bsdf_name, layer.microfacet_weight])

                    # Kelemen
                    elif layer.bsdf_type == "kelemen_brdf":
                        kelemen_bsdf_name = "{0}|{1}".format(material_name, layer.name)
                        self.__emit_kelemen_brdf(material, kelemen_bsdf_name, scene, layer)
                        # Layer mask textures.
                        if layer.kelemen_use_tex and layer.kelemen_mix_tex != '':   
                            bsdfs.append( [ kelemen_bsdf_name, layer.kelemen_mix_tex + "_inst"])

                            mix_tex_name = layer.kelemen_mix_tex + "_inst"
                            if mix_tex_name not in self._textures_set:
                                self.__emit_texture( bpy.data.textures[ layer.kelemen_mix_tex], False, scene)
                                self._textures_set.add( mix_tex_name)
                        else:
                            bsdfs.append([ kelemen_bsdf_name, layer.kelemen_weight])
                      
                return self.__emit_bsdf_mixes(bsdfs)

    #----------------------
    # Write back material.
    #----------------------
    def __emit_back_material_bsdf_tree(self, material, material_name, scene, layers, material_node = None, node_list = None):
        # material_name = material.name  + "_back"
        # Need to include all instances of Specular BTDFs.
        if material_node is not None:
            for node in node_list:
                if node.node_type == "specular_btdf":
                    transp_bsdf_name = "{0}|{1}".format( material_name, node.name) 
                    
                    self.__emit_specular_btdf(material, transp_bsdf_name, scene, 'back', None, node)
                    break
        else:
            spec_btdfs = []
            for layer in layers:
                if layer.bsdf_type == "specular_btdf":
                    # This is a hack for now; just return the first one we find
                    spec_btdfs.append([layer.name, layer.spec_btdf_weight])
                    transp_bsdf_name = "{0}|{1}".format(material_name, spec_btdfs[0][0]) 
                    
                    self.__emit_specular_btdf(material, transp_bsdf_name, scene, 'back', layer)
                    break
        return transp_bsdf_name

    #-----------------------------
    # Write BSDF blends / weights.
    #-----------------------------
    def __emit_bsdf_mixes(self, bsdfs):
        
        # Only one BSDF, no blending.
        if len(bsdfs) == 1:
            return bsdfs[0][0]

        # Normalize weights if necessary.
        total_weight = 0.0
        for bsdf in bsdfs:
            if isinstance( bsdf[1], ( float, int)):
                total_weight += bsdf[1]
        if total_weight > 1.0:
            for bsdf in bsdfs:
                if isinstance( bsdf[1], ( float, int)):
                    bsdf[1] /= total_weight

        # The left branch is simply the first BSDF.
        bsdf0_name = bsdfs[0][0]
        bsdf0_weight = bsdfs[0][1]

        # The right branch is a blend of all the other BSDFs (recurse).
        bsdf1_name = self.__emit_bsdf_mixes(bsdfs[1:])
        bsdf1_weight = 1.0 - bsdf0_weight if isinstance( bsdf0_weight, ( float, int)) else 1.0

        # Blend the left and right branches together.
        mix_name = "{0}+{1}".format(bsdf0_name, bsdf1_name)
        self.__emit_bsdf_mix(mix_name, bsdf0_name, bsdf0_weight, bsdf1_name, bsdf1_weight)
            
        return mix_name

    #----------------------
    # Write Lambertian BRDF.
    #----------------------
    def __emit_lambertian_brdf(self, material, bsdf_name, scene, layer = None, node = None):
        asr_mat = material.appleseed
        reflectance_name = ""

        # Nodes.
        if node is not None:
            inputs = node.inputs
            reflectance_name = inputs["Reflectance"].get_socket_value( True)
            
            # If the socket is not connected.
            if not inputs["Reflectance"].is_linked:
                lambertian_reflectance = reflectance_name
                reflectance_name = "{0}_lambertian_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name,
                                                       lambertian_reflectance,
                                                       1)
            reflectance_multiplier = inputs["Multiplier"].get_socket_value( True)

        else:
            if layer.lambertian_use_diff_tex and layer.lambertian_diffuse_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.lambertian_diffuse_tex]):
                    reflectance_name = layer.lambertian_diffuse_tex + "_inst"
                    if reflectance_name not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.lambertian_diffuse_tex], False, scene)
                        self._textures_set.add( reflectance_name)
            # TODO: add texture support for multiplier
            reflectance_multiplier = layer.lambertian_multiplier
                        
            if reflectance_name == "":            
                reflectance_name = "{0}_lambertian_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element( reflectance_name,
                                                       layer.lambertian_reflectance,
                                                       1)
        # Emit BRDF.
        self.__open_element('bsdf name="{0}" model="lambertian_brdf"'.format(bsdf_name))
        self.__emit_parameter("reflectance", reflectance_name)
        self.__emit_parameter("reflectance_multiplier", reflectance_multiplier)
        self.__close_element("bsdf")


    #-----------------------
    # Write Disney BRDF.
    #-----------------------
    def __emit_disney_brdf( self, material, bsdf_name, scene, layer = None, node = None):
        asr_mat = material.appleseed
        base_coat_name = ""
        
        # Nodes.
        if node is not None:
            inputs = node.inputs
            base_coat_name = inputs["Base Coat"].get_socket_value( True)
            spec = inputs["Specular"].get_socket_value( True)
            spec_tint = inputs["Specular Tint"].get_socket_value( True)
            aniso = inputs["Anisotropy"].get_socket_value( True)
            metallic = inputs["Metallic"].get_socket_value( True)
            roughness = inputs["Roughness"].get_socket_value( True)
            clearcoat = inputs["Clear Coat"].get_socket_value( True)
            clearcoat_gloss = inputs["Clear Coat Gloss"].get_socket_value( True)
            sheen = inputs["Sheen"].get_socket_value( True)
            sheen_tint = inputs["Sheen Tint"].get_socket_value( True)
            subsurface = inputs["Subsurface"].get_socket_value( True)
            
            # If the socket is not connected.
            if not inputs["Base Coat"].is_linked:
                base_coat_color = base_coat_name
                base_coat_name = "{0}_disney_base_coat".format( bsdf_name)
                self.__emit_solid_linear_rgb_color_element( base_coat_name,
                                                       base_coat_color,
                                                       1)
        else:
            # Base Coat.
            if layer.disney_use_base_tex and layer.disney_base_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_base_tex]):
                    base_coat_name = layer.disney_base_tex + "_inst"
                    if base_coat_name not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_base_tex], False, scene)
                        self._textures_set.add( base_coat_name)

            else:
                base_coat_name = "{0}_disney_base_coat".format( bsdf_name)
                self.__emit_solid_linear_rgb_color_element( base_coat_name, 
                                                        layer.disney_base,
                                                        1)

            # Specular.
            spec = layer.disney_spec
            if layer.disney_use_spec_tex and layer.disney_spec_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_spec_tex]):
                    spec = layer.disney_spec_tex + "_inst"
                    if spec not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_spec_tex], False, scene)
                        self._textures_set.add( spec)

            # Specular Tint.
            spec_tint = layer.disney_spec_tint
            if layer.disney_use_spec_tint_tex and layer.disney_spec_tint_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_spec_tint_tex]):
                    spec_tint = layer.disney_spec_tint_tex + "_inst"
                    if spec_tint not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_spec_tint_tex], False, scene)
                        self._textures_set.add( spec_tint)

            # Aniso.
            aniso = layer.disney_aniso
            if layer.disney_use_aniso_tex and layer.disney_aniso_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_aniso_tex]):
                    aniso = layer.disney_aniso_tex + "_inst"
                    if aniso not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_aniso_tex], False, scene)
                        self._textures_set.add( aniso)

            # Clear Coat.
            clearcoat = layer.disney_clearcoat
            if layer.disney_use_clearcoat_tex and layer.disney_clearcoat_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_clearcoat_tex]):
                    clearcoat = layer.disney_clearcoat_tex + "_inst"
                    if clearcoat not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_clearcoat_tex], False, scene)
                        self._textures_set.add( clearcoat)

            # Clear Coat Gloss.
            clearcoat_gloss = layer.disney_clearcoat_gloss
            if layer.disney_use_clearcoat_gloss_tex and layer.disney_clearcoat_gloss_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_clearcoat_gloss_tex]):
                    clearcoat_gloss = layer.disney_clearcoat_gloss_tex + "_inst"
                    if clearcoat_gloss not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_clearcoat_gloss_tex], False, scene)
                        self._textures_set.add( clearcoat_gloss)

            # Metallic.
            metallic = layer.disney_metallic
            if layer.disney_use_metallic_tex and layer.disney_metallic_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_metallic_tex]):
                    metallic = layer.disney_metallic_tex + "_inst"
                    if metallic not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_metallic_tex], False, scene)
                        self._textures_set.add( metallic)

            # Roughness.
            roughness = layer.disney_roughness
            if layer.disney_use_roughness_tex and layer.disney_roughness_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_roughness_tex]):
                    roughness = layer.disney_roughness_tex + "_inst"
                    if roughness not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_roughness_tex], False, scene)
                        self._textures_set.add( roughness)

            # Sheen.
            sheen = layer.disney_sheen
            if layer.disney_use_sheen_tex and layer.disney_sheen_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_sheen_tex]):
                    sheen = layer.disney_sheen_tex + "_inst"
                    if sheen not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_sheen_tex], False, scene)
                        self._textures_set.add( sheen)
                        
            # Sheen Tint.
            sheen_tint = layer.disney_sheen_tint
            if layer.disney_use_sheen_tint_tex and layer.disney_sheen_tint_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_sheen_tint_tex]):
                    sheen_tint = layer.disney_sheen_tint_tex + "_inst"
                    if sheen_tint not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_sheen_tint_tex], False, scene)
                        self._textures_set.add( sheen_tint)

            # Subsurface.
            subsurface = layer.disney_subsurface
            if layer.disney_use_subsurface_tex and layer.disney_subsurface_tex != '':
                if util.is_uv_img( bpy.data.textures[layer.disney_subsurface_tex]):
                    subsurface = layer.disney_subsurface_tex + "_inst"
                    if subsurface not in self._textures_set:
                        self.__emit_texture( bpy.data.textures[layer.disney_subsurface_tex], False, scene)
                        self._textures_set.add( subsurface)

        self.__open_element('bsdf name="{0}" model="disney_brdf"'.format(bsdf_name))
        self.__emit_parameter("anisotropic", aniso)
        self.__emit_parameter("base_color", base_coat_name)
        self.__emit_parameter("specular", spec)
        self.__emit_parameter("specular_tint", spec_tint)
        self.__emit_parameter("clearcoat", clearcoat)
        self.__emit_parameter("clearcoat_gloss", clearcoat_gloss)
        self.__emit_parameter("metallic", metallic)
        self.__emit_parameter("roughness", roughness)
        self.__emit_parameter("sheen", sheen)
        self.__emit_parameter("sheen_tint", sheen_tint)
        self.__emit_parameter("subsurface", subsurface)
        self.__close_element("bsdf")
            
    #-----------------------
    # Write Oren-Nayar BRDF.
    #-----------------------
    def __emit_orennayar_brdf(self, material, bsdf_name, scene, layer = None, node = None):
        asr_mat = material.appleseed
        reflectance_name = ""

        # Nodes.
        if node is not None:
            inputs = node.inputs
            reflectance_name = inputs["Reflectance"].get_socket_value( True)
            reflectance_multiplier = inputs["Multiplier"].get_socket_value( True)
            roughness = inputs["Roughness"].get_socket_value( True)
            
            # If the socket is not connected.
            if not inputs["Reflectance"].is_linked:
                orennayar_reflectance = reflectance_name
                reflectance_name = "{0}_orennayar_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element( reflectance_name,
                                                       orennayar_reflectance,
                                                       1)

        else:
            roughness = layer.orennayar_roughness           
            if layer.orennayar_use_diff_tex and layer.orennayar_diffuse_tex != '':
                if util.is_uv_img(bpy.data.textures[layer.orennayar_diffuse_tex]):
                    reflectance_name = layer.orennayar_diffuse_tex + "_inst"
                    if reflectance_name not in self._textures_set:
                        self.__emit_texture(bpy.data.textures[layer.orennayar_diffuse_tex], False, scene)
                        self._textures_set.add(reflectance_name)
            
            if layer.orennayar_use_rough_tex and layer.orennayar_rough_tex != '':
                if util.is_uv_img(bpy.data.textures[layer.orennayar_rough_tex]):
                    roughness = layer.orennayar_rough_tex + "_inst"
                    if roughness not in self._textures_set:
                        self.__emit_texture(bpy.data.textures[layer.orennayar_rough_tex], False, scene)
                        self._textures_set.add(roughness)
                        
            # TODO: add texture support for multiplier
            reflectance_multiplier = layer.orennayar_multiplier
            
            if reflectance_name == "":            
                reflectance_name = "{0}_orennayar_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name,
                                                       layer.orennayar_reflectance,
                                                       1)

        self.__open_element('bsdf name="{0}" model="orennayar_brdf"'.format(bsdf_name))
        self.__emit_parameter("reflectance", reflectance_name)
        self.__emit_parameter("reflectance_multiplier", reflectance_multiplier)
        self.__emit_parameter("roughness", roughness)
        self.__close_element("bsdf")

    #----------------------
    # Write Diffuse BTDF.
    #----------------------
    def __emit_diffuse_btdf(self, material, bsdf_name, scene, layer = None, node = None):      
        asr_mat = material.appleseed  
        transmittance_name = ""

        # Nodes.
        if node is not None:
            inputs = node.inputs
            transmittance_name = inputs["Reflectance"].get_socket_value( True)
            transmittance = inputs["Multiplier"].get_socket_value( True)
            
            # If the socket is not connected.
            if not inputs["Reflectance"].is_linked:
                transmittance_color = transmittance_name
                transmittance_name = "{0}_diffuse_transmittance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(transmittance_name,
                                                       transmittance_color,
                                                       1)
                                                       
        else:
            if layer.transmittance_use_diff_tex and layer.transmittance_diff_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.transmittance_diff_tex]):    
                    transmittance_name = layer.transmittance_diff_tex + "_inst"
                    if transmittance_name not in self._textures_set:
                        self._textures_set.add(transmittance_name)
                        self.__emit_texture(bpy.data.textures[layer.transmittance_diff_tex], False, scene)

            if layer.transmittance_use_mult_tex and layer.transmittance_mult_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.transmittance_mult_tex]):    
                    transmittance = layer.transmittance_mult_tex + "_inst"
                    if transmittance not in self._textures_set:
                        self._textures_set.add(transmittance)
                        self.__emit_texture(bpy.data.textures[layer.transmittance_mult_tex], False, scene)
                        
            if transmittance_name == "":
                transmittance_name = "{0}_diffuse_transmittance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(transmittance_name, 
                                                        layer.transmittance_color,
                                                        1)
            # TODO: add texture support for multiplier
            transmittance = layer.transmittance_multiplier
                                  
        self.__open_element('bsdf name="{0}" model="diffuse_btdf"'.format(bsdf_name))
        self.__emit_parameter("transmittance", transmittance_name)
        self.__emit_parameter("transmittance_multiplier", transmittance)
        self.__close_element("bsdf")

    #-----------------------------
    # Write Ashikhmin-Shirley BRDF.
    #-----------------------------
    def __emit_ashikhmin_brdf(self, material, bsdf_name, scene, layer = None, node = None):
        asr_mat = material.appleseed
        diffuse_reflectance_name = ""
        glossy_reflectance_name = ""

        # Nodes.
        if node is not None:
            inputs = node.inputs
            diffuse_reflectance_name = inputs["Reflectance"].get_socket_value( True)
            diffuse_multiplier = inputs["Multiplier"].get_socket_value( True)
            glossy_reflectance_name = inputs["Glossy Reflectance"].get_socket_value( True)
            shininess_u = inputs["Shininess U"].get_socket_value( True)
            shininess_v = inputs["Shininess V"].get_socket_value( True)
            fresnel = inputs["Fresnel Multiplier"].get_socket_value( True)
            
            # If the socket is not connected.
            if not inputs["Reflectance"].is_linked:
                ashikhmin_reflectance = diffuse_reflectance_name
                diffuse_reflectance_name = "{0}_ashikhmin_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(diffuse_reflectance_name,
                                                       ashikhmin_reflectance,
                                                       1) 
            if not inputs["Glossy Reflectance"].is_linked:
                ashikhmin_glossy = glossy_reflectance_name    
                glossy_reflectance_name = "{0}_ashikhmin_glossy_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(glossy_reflectance_name,
                                                       ashikhmin_glossy,
                                                       1)

        else:
            if layer.ashikhmin_use_diff_tex and layer.ashikhmin_diffuse_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.ashikhmin_diffuse_tex]):    
                    diffuse_reflectance_name = layer.ashikhmin_diffuse_tex + "_inst"
                    if diffuse_reflectance_name not in self._textures_set:
                        self._textures_set.add(diffuse_reflectance_name)
                        self.__emit_texture(bpy.data.textures[layer.ashikhmin_diffuse_tex], False, scene)
                    
            if layer.ashikhmin_use_gloss_tex and layer.ashikhmin_gloss_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.ashikhmin_gloss_tex]):    
                    glossy_reflectance_name = layer.ashikhmin_gloss_tex + "_inst"
                    if glossy_reflectance_name not in self._textures_set:
                        self.__emit_texture(bpy.data.textures[layer.ashikhmin_gloss_tex], False, scene)
                        self._textures_set.add(glossy_reflectance_name)
                
            #Make sure we found some textures. If not, default to material color.
            if diffuse_reflectance_name == "":
                diffuse_reflectance_name = "{0}_ashikhmin_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(diffuse_reflectance_name,
                                                       layer.ashikhmin_reflectance,
                                                       1)
            if glossy_reflectance_name == "":    
                glossy_reflectance_name = "{0}_ashikhmin_glossy_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(glossy_reflectance_name,
                                                       layer.ashikhmin_glossy,
                                                       1)
            # TODO: add texture support
            shininess_u = layer.ashikhmin_shininess_u
            shininess_v = layer.ashikhmin_shininess_v
            diffuse_multiplier = layer.ashikhmin_multiplier
            fresnel = 1
            
        self.__open_element('bsdf name="{0}" model="ashikhmin_brdf"'.format(bsdf_name))
        self.__emit_parameter("diffuse_reflectance", diffuse_reflectance_name)
        self.__emit_parameter("diffuse_reflectance_multiplier", diffuse_multiplier)
        self.__emit_parameter("glossy_reflectance", glossy_reflectance_name)
        self.__emit_parameter("shininess_u", shininess_u)
        self.__emit_parameter("shininess_v", shininess_v)
        self.__emit_parameter("fresnel_multiplier", fresnel)
        self.__close_element("bsdf")

    #----------------------
    # Write Specular BRDF.
    #----------------------
    def __emit_specular_brdf(self, material, bsdf_name, scene, layer = None, node = None):
        asr_mat = material.appleseed
        reflectance_name = ""

        # Nodes.
        if node is not None:
            inputs = node.inputs
            reflectance_name = inputs["Reflectance"].get_socket_value( True)
            multiplier = inputs["Multiplier"].get_socket_value( True)
            
            # If the socket is not connected.
            if not inputs["Reflectance"].is_linked:
                specular_reflectance = reflectance_name
                reflectance_name = "{0}_specular_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name,
                                                       specular_reflectance,
                                                       1)

        else:
            if layer.specular_use_gloss_tex and layer.specular_gloss_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.specular_gloss_tex]):    

                    reflectance_name = layer.specular_gloss_tex + "_inst"
                    if reflectance_name not in self._textures_set:

                        self._textures_set.add(reflectance_name)
                        self.__emit_texture(bpy.data.textures[layer.specular_gloss_tex], False, scene)
            if reflectance_name == "":
                reflectance_name = "{0}_specular_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name, 
                                                        layer.specular_reflectance, 
                                                        1)
            # TODO: add texture support for multiplier
            multiplier = layer.specular_multiplier
            
        self.__open_element('bsdf name="{0}" model="specular_brdf"'.format(bsdf_name))
        self.__emit_parameter("reflectance", reflectance_name)
        self.__emit_parameter("reflectance_multiplier", multiplier)
        self.__close_element("bsdf")

    #----------------------
    # Write Specular BTDF.
    #----------------------
    def __emit_specular_btdf(self, material, bsdf_name, scene, side, layer, node = None):
        assert side == 'front' or side == 'back'
        asr_mat = material.appleseed
        reflectance_name = ""
        transmittance_name = ""

        # Nodes.
        if node is not None:
            inputs = node.inputs
            reflectance_name = inputs[0].get_socket_value( True)
            reflectance_multiplier = inputs[1].get_socket_value( True)
            transmittance_name = inputs[2].get_socket_value( True)
            transmittance_multiplier = inputs[3].get_socket_value( True)
            if side == 'front':
                from_ior = node.from_ior
                to_ior = node.to_ior
            else:
                from_ior = node.to_ior
                to_ior = node.from_ior

            if not inputs[0].is_linked:
                spec_btdf_reflectance = reflectance_name
                reflectance_name = "{0}_transp_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name, 
                                                        spec_btdf_reflectance, 
                                                        1)
            if not inputs[2].is_linked:
                spec_btdf_transmittance = transmittance_name
                transmittance_name = "{0}_transp_transmittance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(transmittance_name, 
                                                        spec_btdf_transmittance, 
                                                        1)
        else:
            if layer.spec_btdf_use_spec_tex and layer.spec_btdf_spec_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.spec_btdf_spec_tex]):    
                    reflectance_name = layer.spec_btdf_spec_tex + "_inst"
                    if reflectance_name not in self._textures_set:
                        self._textures_set.add(reflectance_name)
                        self.__emit_texture(bpy.data.textures[layer.spec_btdf_spec_tex], False, scene)
            if reflectance_name == "":        
                reflectance_name = "{0}_transp_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name, 
                                                        layer.spec_btdf_reflectance, 
                                                        1)
            
            if layer.spec_btdf_use_trans_tex and layer.spec_btdf_trans_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.spec_btdf_trans_tex]):    
                    transmittance_name = layer.spec_btdf_trans_tex + "_inst"
                    if transmittance_name not in self._textures_set:
                        self._textures_set.add(transmittance_name)
                        self.__emit_texture(bpy.data.textures[layer.spec_btdf_trans_tex], False, scene)
            
            if transmittance_name == "":            
                transmittance_name = "{0}_transp_transmittance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(transmittance_name, 
                                                        layer.spec_btdf_transmittance, 
                                                        1)
            # TODO: add texture support for multiplier                                  
            reflectance_multiplier = layer.spec_btdf_refl_mult
            transmittance_multiplier = layer.spec_btdf_trans_mult
            
            if side == 'front':
                from_ior = layer.spec_btdf_from_ior
                to_ior = layer.spec_btdf_to_ior
            else:
                from_ior = layer.spec_btdf_to_ior
                to_ior = layer.spec_btdf_from_ior


        self.__open_element('bsdf name="{0}" model="specular_btdf"'.format(bsdf_name))
        self.__emit_parameter("reflectance", reflectance_name)
        self.__emit_parameter("reflectance_multiplier", reflectance_multiplier)
        self.__emit_parameter("transmittance", transmittance_name)
        self.__emit_parameter("transmittance_multiplier", transmittance_multiplier)
        self.__emit_parameter("from_ior", from_ior)
        self.__emit_parameter("to_ior", to_ior)
        self.__close_element("bsdf")
    
    #-----------------------
    # Write Microfacet BRDF.
    #-----------------------
    def __emit_microfacet_brdf(self, material, bsdf_name, scene, layer = None, node = None):
        asr_mat = material.appleseed
        reflectance_name = ""
        mdf_refl = ""

        if node is not None:
            inputs = node.inputs
            microfacet_model = node.microfacet_model
            reflectance_name = inputs[0].get_socket_value( True)
            microfacet_multiplier = inputs[1].get_socket_value( True)
            mdf_refl = inputs[2].get_socket_value( True)
            microfacet_mdf_multiplier = inputs[3].get_socket_value( True)
            microfacet_fresnel = inputs[4].get_socket_value( True)
            
            if not inputs[0].is_linked:
                microfacet_reflectance = reflectance_name
                reflectance_name = "{0}_microfacet_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name, 
                                                        microfacet_reflectance, 
                                                        1)
        else:
            if layer.microfacet_use_diff_tex and layer.microfacet_diff_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.microfacet_diff_tex]):
                    reflectance_name = layer.microfacet_diff_tex + "_inst"
                    if reflectance_name not in self._textures_set:
                        self.__emit_texture(bpy.data.textures[layer.microfacet_diff_tex], False, scene)
                        self._textures_set.add(reflectance_name)
            
            if reflectance_name == "":
                reflectance_name = "{0}_microfacet_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name,
                                                       layer.microfacet_reflectance,
                                                       1)
                                                       
            if layer.microfacet_use_spec_tex and layer.microfacet_spec_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.microfacet_spec_tex]):    
                    mdf_refl = layer.microfacet_spec_tex + "_inst"
                    if mdf_refl not in self._textures_set:
                        self.__emit_texture(bpy.data.textures[layer.microfacet_spec_tex], False, scene)
                        self._textures_set.add(mdf_refl)
            if mdf_refl == "":
                #This changes to a float, if it's not a texture
                mdf_refl = layer.microfacet_mdf

            # TODO: add texture support for multiplier
            microfacet_model = layer.microfacet_model
            microfacet_multiplier = layer.microfacet_multiplier
            microfacet_mdf_multiplier = layer.microfacet_mdf_multiplier
            microfacet_fresnel = layer.microfacet_fresnel
            
        self.__open_element('bsdf name="{0}" model="microfacet_brdf"'.format(bsdf_name))
        self.__emit_parameter("mdf", microfacet_model)
        self.__emit_parameter("reflectance", reflectance_name)
        self.__emit_parameter("reflectance_multiplier", microfacet_multiplier)
        self.__emit_parameter("glossiness", mdf_refl)
        self.__emit_parameter("glossiness_multiplier", microfacet_mdf_multiplier)
        self.__emit_parameter("fresnel_multiplier", microfacet_fresnel)
        self.__close_element("bsdf")
               
    #----------------------
    # Write Kelemen BRDF.
    #----------------------
    def __emit_kelemen_brdf(self, material, bsdf_name, scene, layer = None, node = None):
        asr_mat = material.appleseed
        reflectance_name = ""
        spec_refl_name  = ""

        if node is not None:
            inputs = node.inputs
            reflectance_name = inputs[0].get_socket_value( True)
            kelemen_matte_multiplier = inputs[1].get_socket_value( True)
            spec_refl_name = inputs[2].get_socket_value( True)
            kelemen_specular_multiplier = inputs[3].get_socket_value( True)
            kelemen_roughness = inputs[4].get_socket_value( True)
            
            if not inputs[0].is_linked:
                kelemen_matte_reflectance = reflectance_name
                reflectance_name = "{0}_kelemen_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name,
                                                       kelemen_matte_reflectance,
                                                       1)
            if not inputs[2].is_linked:
                kelemen_specular_reflectance = spec_refl_name
                spec_refl_name = "{0}_kelemen_specular".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(spec_refl_name, 
                                                        kelemen_specular_reflectance,
                                                        1)
        else:
            if layer.kelemen_use_diff_tex:
                if layer.kelemen_diff_tex != "":
                    if util.is_uv_img(bpy.data.textures[layer.kelemen_diff_tex]):
                        reflectance_name = layer.kelemen_diff_tex + "_inst"
                        if reflectance_name not in self._textures_set:
                            self._textures_set.add(reflectance_name)
                            self.__emit_texture(bpy.data.textures[layer.kelemen_diff_tex], False, scene)
            
            if reflectance_name == "":
                reflectance_name = "{0}_kelemen_reflectance".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(reflectance_name,
                                                       layer.kelemen_matte_reflectance,
                                                       1)
            if layer.kelemen_use_spec_tex and layer.kelemen_spec_tex != "":
                if util.is_uv_img(bpy.data.textures[layer.kelemen_spec_tex]):    
                    spec_refl_name = layer.kelemen_spec_tex + "_inst"
                    if spec_refl_name not in self._textures_set:
                        self._textures_set.add(spec_refl_name)
                        self.__emit_texture(bpy.data.textures[layer.kelemen_spec_tex], False, scene)
            if spec_refl_name == "":
                spec_refl_name = "{0}_kelemen_specular".format(bsdf_name)
                self.__emit_solid_linear_rgb_color_element(spec_refl_name, 
                                                        layer.kelemen_specular_reflectance,
                                                        1)
            # TODO: add texture support
            kelemen_roughness = layer.kelemen_roughness  
            kelemen_specular_multiplier = layer.kelemen_specular_multiplier
            kelemen_matte_multiplier = layer.kelemen_matte_multiplier
            
        self.__open_element('bsdf name="{0}" model="kelemen_brdf"'.format(bsdf_name))
        self.__emit_parameter("matte_reflectance", reflectance_name)
        self.__emit_parameter("matte_reflectance_multiplier", kelemen_matte_multiplier)
        self.__emit_parameter("roughness", kelemen_roughness)
        self.__emit_parameter("specular_reflectance", spec_refl_name)
        self.__emit_parameter("specular_reflectance_multiplier", kelemen_specular_multiplier)
        self.__close_element("bsdf")
    
    #----------------------
    # Write BSDF Mixes.
    #----------------------
    def __emit_bsdf_mix(self, bsdf_name, bsdf0_name, bsdf0_weight, bsdf1_name, bsdf1_weight):
        '''
        Emit BSDF mix to project file.
        '''
        self.__open_element('bsdf name="{0}" model="bsdf_mix"'.format(bsdf_name))
        self.__emit_parameter("bsdf0", bsdf0_name)
        self.__emit_parameter("weight0", bsdf0_weight)
        self.__emit_parameter("bsdf1", bsdf1_name)
        self.__emit_parameter("weight1", bsdf1_weight)
        self.__close_element("bsdf")

    #----------------------
    # Write BSDF Blend.
    #----------------------
    def __emit_bsdf_blend(self, bsdf_name, material_name, node = None):
        '''
        Emit BSDF blend to project file.
        '''
        if node is not None:
            inputs = node.inputs
            weight = inputs[0].get_socket_value( True)
            bsdf0_name = material_name + inputs[1].get_socket_value( False)
            bsdf1_name = material_name + inputs[2].get_socket_value( False)

            if isinstance(weight, float):
                weight = 1 - weight
                
        self.__open_element('bsdf name="{0}" model="bsdf_blend"'.format(bsdf_name))
        self.__emit_parameter("bsdf0", bsdf0_name)
        self.__emit_parameter("bsdf1", bsdf1_name)
        self.__emit_parameter("weight", weight)
        self.__close_element("bsdf")

    #----------------------
    # Write material emission.
    #----------------------
    def __emit_edf(self, material, edf_name, scene, material_node = None):
        asr_mat = material.appleseed
        # Nodes.
        if material_node is not None:
            inputs = material_node.inputs
            radiance_name = inputs["Emission Color"].get_socket_value( True)
            radiance_multiplier = inputs["Emission Strength"].get_socket_value( True)
            
            if not inputs["Emission Color"].is_linked:
                radiance_name = "{0}_radiance".format(edf_name)
                self.__emit_solid_linear_rgb_color_element( radiance_name,
                                                           material_node.inputs["Emission Color"].socket_value,
                                                           scene.appleseed.light_mats_radiance_multiplier) 
            
        else:
            radiance_name = "{0}_radiance".format(edf_name)
            radiance_multiplier = asr_mat.light_emission
            self.__emit_solid_linear_rgb_color_element(radiance_name,
                                                       asr_mat.light_color,
                                                       scene.appleseed.light_mats_radiance_multiplier)
                                                       
        self.__emit_diffuse_edf_element( asr_mat, edf_name, radiance_name, radiance_multiplier, material_node)

    
    def __emit_diffuse_edf_element(self, asr_mat, edf_name, radiance_name, radiance_multiplier, material_node = None):
        '''
        Emit the EDF to the project file.
        '''
        if material_node is not None:
            cast_indirect = material_node.cast_indirect
            importance_multiplier = material_node.importance_multiplier
            light_near_start = material_node.light_near_start
        else:
            cast_indirect = str(asr_mat.cast_indirect).lower()
            importance_multiplier = asr_mat.importance_multiplier
            light_near_start = asr_mat.light_near_start
            
        self.__open_element('edf name="{0}" model="diffuse_edf"'.format(edf_name))
        self.__emit_parameter("radiance", radiance_name)
        self.__emit_parameter("radiance_multiplier", radiance_multiplier)
        self.__emit_parameter("cast_indirect_light", cast_indirect)
        self.__emit_parameter("importance_multiplier", importance_multiplier)
        self.__emit_parameter("light_near_start", light_near_start)
        self.__close_element("edf")

    #----------------------------------------------------------------------------------------------
    # Export textures, if any exist on the material
    #----------------------------------------------------------------------------------------------
    # Write texture.
    def __emit_texture(self, texture, bump_bool, scene, node = None, material_name = None, scene_texture = False):
        if scene_texture:
            # texture is an absolute file path string.
            # Assume the path ends with '.png' or '.exr'.
            texture_name = texture.split( util.sep)[-1][:-4]
            filepath = texture
            color_space = 'srgb'
        elif node is not None:
            texture_name = node.get_node_name()
            filepath = util.realpath( node.tex_path)
            color_space = node.color_space
        else:        
            if texture.image.colorspace_settings.name == 'Linear':
                color_space = 'linear_rgb'
            elif texture.image.colorspace_settings.name == 'XYZ':
                color_space = 'ciexyz'
            else:
                color_space = 'srgb'      

            filepath = util.realpath( texture.image.filepath)
            texture_name = texture.name if bump_bool == False else texture.name + "_bump"
            
        self.__open_element('texture name="{0}" model="disk_texture_2d"'.format( texture_name))
        self.__emit_parameter("color_space", color_space)
        self.__emit_parameter("filename", filepath)
        self.__close_element("texture")
        
        # Now create texture instance.
        self.__emit_texture_instance(texture, texture_name, bump_bool, node, material_name, scene_texture)

    # Write texture instance.
    def __emit_texture_instance(self, texture, texture_name, bump_bool, node = None, material_name = None, scene_texture = False):
        if scene_texture:
            mode = "clamp"
        elif node is not None:
            mode = node.mode
        else:
            mode = "wrap" if texture.extension == "REPEAT" else "clamp"        
            
        self.__open_element('texture_instance name="{0}_inst" texture="{1}"'.format(texture_name, texture_name))
        self.__emit_parameter("addressing_mode", mode)
        self.__emit_parameter("filtering_mode", "bilinear")
        self.__close_element("texture_instance")   
        
        
    #----------------------------------------------------------------------------------------------
    # Create the material                                       
    #----------------------------------------------------------------------------------------------

    def __emit_material_element(self, material_name, bsdf_name, edf_name, surface_shader_name, scene, material, material_node = None):
        if material != "":
            asr_mat = material.appleseed
        bump_map = ""
        material_alpha_map = 1.0
        material_bump_amplitude = 1.0
        method = "bump"

        # Check whether evaluating default material.
        if material != "":   
            # Node material.
            if material_node is not None:
                inputs = material_node.inputs
                material_alpha_map = inputs[1].get_socket_value( True)
                bump_map = inputs[2].get_socket_value( False)
                if bump_map != "":
                    bump_map =  bump_map + "_inst"
                    material_bump_amplitude, use_normalmap = inputs[2].get_normal_params()
                    method = "normal" if use_normalmap else "bump"
            else:
                if asr_mat.material_use_bump_tex:
                    if asr_mat.material_bump_tex != "":
                        if util.is_uv_img(bpy.data.textures[asr_mat.material_bump_tex]):
                            bump_map = asr_mat.material_bump_tex + "_bump"
                                    
                if bump_map != "":
                    if bump_map not in self._textures_set:
                        self.__emit_texture(bpy.data.textures[asr_mat.material_bump_tex], True, scene)
                        self._textures_set.add(bump_map)    
                    material_bump_amplitude = asr_mat.material_bump_amplitude
                    bump_map += "_inst"
                    method = "normal" if asr_mat.material_use_normalmap else "bump"
   
                if asr_mat.material_use_alpha and asr_mat.material_alpha_map != "":
                    material_alpha_map = asr_mat.material_alpha_map + "_inst"
                    if asr_mat.material_alpha_map + "_inst" not in self._textures_set:
                        self.__emit_texture(bpy.data.textures[asr_mat.material_alpha_map], False, scene)
                        self._textures_set.add(asr_mat.material_alpha_map + "_inst")
                else:
                    material_alpha_map = asr_mat.material_alpha
                
        self.__open_element( 'material name="{0}" model="generic_material"'.format(material_name))
        if material_alpha_map != 1.0:
            self.__emit_parameter( "alpha_map", material_alpha_map)
        if len( bsdf_name) > 0:
            self.__emit_parameter( "bsdf", bsdf_name)
        if len( edf_name) > 0:
            self.__emit_parameter("edf", edf_name)
        
        if bump_map != "":
            self.__emit_parameter( "displacement_map", bump_map)
        self.__emit_parameter( "bump_amplitude", material_bump_amplitude)
        self.__emit_parameter( "displacement_method", method)
        self.__emit_parameter( "normal_map_up", "z")
        self.__emit_parameter( "shade_alpha_cutouts", "false")
        self.__emit_parameter( "surface_shader", surface_shader_name)
        self.__close_element( "material")

    #----------------------------------------------------------------------------------------------
    # Camera.
    #----------------------------------------------------------------------------------------------
    
    def __emit_camera(self, scene):
        asr_scn = scene.appleseed
        shutter_open = asr_scn.shutter_open if asr_scn.mblur_enable else 0
        shutter_close = asr_scn.shutter_close if asr_scn.mblur_enable else 1
        camera = scene.camera
        width = scene.render.resolution_x
        height = scene.render.resolution_y
        emit_diaphragm_map = False
        
        if camera is None:
            self.__warning("No camera in the scene, exporting a default camera.")
            self.__emit_default_camera_element()
            return

        render = scene.render

        film_width = camera.data.sensor_width / 1000
        aspect_ratio = self.__get_frame_aspect_ratio(render)
        lens_unit = "focal_length" if camera.data.lens_unit == 'MILLIMETERS' else "horizontal_fov"

        # Blender's camera focal length is expressed in mm
        focal_length = camera.data.lens / 1000.0                
        fov = util.calc_fov( camera, width, height)
        
        # Test if using focal object, get focal distance.
        if camera.data.dof_object is not None:
            cam_target = bpy.data.objects[camera.data.dof_object.name]
            focal_distance = (cam_target.location - camera.location).magnitude
        else:
            focal_distance = camera.data.dof_distance 

        asr_cam = camera.data.appleseed
        cam_model = asr_cam.camera_type
        self.__open_element('camera name="' + camera.name + '" model="{}_camera"'.format(cam_model))
        if cam_model == "thinlens":
            self.__emit_parameter("f_stop", asr_cam.camera_dof)
            self.__emit_parameter("focal_distance", focal_distance)
            self.__emit_parameter("diaphragm_blades", asr_cam.diaphragm_blades)
            self.__emit_parameter("diaphragm_tilt_angle", asr_cam.diaphragm_angle)
            emit_diaphragm_map = False
            if asr_cam.diaphragm_map != '' and asr_cam.diaphragm_map[-3:] in { 'png', 'exr'}:
                emit_diaphragm_map = True
                texture_name = asr_cam.diaphragm_map.split( util.sep)[-1][:-4]
                self.__emit_parameter("diaphragm_map", texture_name + "_inst")
        self.__emit_parameter("film_width", film_width)
        self.__emit_parameter("aspect_ratio", aspect_ratio)
        self.__emit_parameter("horizontal_fov", fov)
        self.__emit_parameter("shutter_open_time", shutter_open)
        self.__emit_parameter("shutter_close_time", shutter_close)

        current_frame = scene.frame_current
        scene.frame_set( current_frame, subframe = shutter_open)
        origin_1, forward_1, up_1, target_1 = util.get_camera_matrix( camera, self._global_matrix)
        
        # Write respective transforms if using camera motion blur.
        if scene.appleseed.mblur_enable and scene.appleseed.cam_mblur:
            scene.frame_set(current_frame, subframe = asr_scn.shutter_close)
            origin_2, forward_2, up_2, target_2 = util.get_camera_matrix( camera, self._global_matrix)
            # Return the timeline to original frame.
            scene.frame_set(current_frame)
            
            self.__open_element('transform time="0"')
            self.__emit_line('<look_at origin="{0} {1} {2}" target="{3} {4} {5}" up="{6} {7} {8}" />'.format( \
                             origin_1[0], origin_1[2], -origin_1[1],
                             target_1[0], target_1[2], -target_1[1],
                             up_1[0], up_1[2], -up_1[1]))
            self.__close_element("transform")
            
            self.__open_element('transform time="1"')
            self.__emit_line('<look_at origin="{0} {1} {2}" target="{3} {4} {5}" up="{6} {7} {8}" />'.format( \
                             origin_2[0], origin_2[2], -origin_2[1],
                             target_2[0], target_2[2], -target_2[1],
                             up_2[0], up_2[2], -up_2[1]))
            self.__close_element("transform")
        else:
            self.__open_element("transform")
            self.__emit_line('<look_at origin="{0} {1} {2}" target="{3} {4} {5}" up="{6} {7} {8}" />'.format( \
                             origin_1[0], origin_1[2], -origin_1[1],
                             target_1[0], target_1[2], -target_1[1],
                             up_1[0], up_1[2], -up_1[1]))
            self.__close_element("transform")
            
        self.__close_element("camera")

        # Write diaphragm texture to Scene, if enabled.
        if emit_diaphragm_map:
            self.__emit_texture( util.realpath( asr_cam.diaphragm_map), False, scene, scene_texture = True)
            
    def __emit_default_camera_element(self):
        self.__open_element('camera name="camera" model="pinhole_camera"')
        self.__emit_parameter("film_width", 0.024892)
        self.__emit_parameter("film_height", 0.018669)
        self.__emit_parameter("focal_length", 0.035)
        self.__close_element("camera")
        return

    #----------------------------------------------------------------------------------------------
    # Environment.
    #----------------------------------------------------------------------------------------------

    def __emit_environment(self, scene):    
        horizon_radiance = [ 0.0, 0.0, 0.0 ]
        zenith_radiance = [ 0.0, 0.0, 0.0 ]

        # Add the contribution of the first hemi light found in the scene.
        found_hemi_light = False
        for object in scene.objects:
            if util.do_export( object, scene):
                if object.type == 'LAMP' and object.data.type == 'HEMI':
                    if not found_hemi_light:
                        self.__info("Using hemi light '{0}' for environment lighting.".format(object.name))
                        hemi_radiance = mul(object.data.color, object.data.energy)
                        horizon_radiance = add(horizon_radiance, hemi_radiance)
                        zenith_radiance = add(zenith_radiance, hemi_radiance)
                        found_hemi_light = True
                    else:
                        self.__warning("Ignoring hemi light '{0}', multiple hemi lights are not supported yet.".format(object.name))

        # Add the contribution of the sky.
        if scene.world is not None:
            horizon_radiance = add(horizon_radiance, scene.world.horizon_color)
            zenith_radiance = add(zenith_radiance, scene.world.zenith_color)

        # Write the environment EDF and environment shader if necessary.
        if is_black(horizon_radiance) and is_black(zenith_radiance) and not scene.appleseed_sky.env_type == "sunsky":
            env_edf_name = ""
            env_shader_name = ""
        else:
            # Write the radiances.
            self.__emit_solid_linear_rgb_color_element("horizon_radiance", horizon_radiance, scene.appleseed_sky.env_radiance_multiplier)
            self.__emit_solid_linear_rgb_color_element("zenith_radiance", zenith_radiance, scene.appleseed_sky.env_radiance_multiplier)

            # Write the environment EDF.
            env_edf_name = "environment_edf"
            if scene.appleseed_sky.env_type == "gradient":
                self.__open_element('environment_edf name="{0}" model="gradient_environment_edf"'.format(env_edf_name))
                self.__emit_parameter("horizon_radiance", "horizon_radiance")
                self.__emit_parameter("zenith_radiance", "zenith_radiance")
                self.__close_element('environment_edf')
                
            elif scene.appleseed_sky.env_type == "constant":
                self.__open_element('environment_edf name="{0}" model="constant_environment_edf"'.format(env_edf_name))
                self.__emit_parameter("radiance", "horizon_radiance")
                self.__close_element('environment_edf')
                
            elif scene.appleseed_sky.env_type == "constant_hemisphere":
                self.__open_element('environment_edf name="{0}" model="constant_hemisphere_environment_edf"'.format(env_edf_name))
                self.__emit_parameter("lower_hemi_radiance", "horizon_radiance")
                self.__emit_parameter("upper_hemi_radiance", "zenith_radiance")
                self.__close_element('environment_edf')
                
            elif scene.appleseed_sky.env_type == "mirrorball_map":
                if scene.appleseed_sky.env_tex != "":
                    self.__emit_texture(bpy.data.textures[scene.appleseed_sky.env_tex], False, scene)
                    self.__open_element('environment_edf name="{0}" model="mirrorball_map_environment_edf"'.format(env_edf_name))
                    self.__emit_parameter("radiance", scene.appleseed_sky.env_tex + "_inst")
                    self.__emit_parameter("radiance_multiplier", scene.appleseed_sky.env_tex_mult)
                    self.__close_element('environment_edf')
                else:
                    self.__warning("Mirror Ball environment texture is enabled, but no texture is assigned. Using gradient environment.")
                    self.__open_element('environment_edf name="{0}" model="gradient_environment_edf"'.format(env_edf_name))
                    self.__emit_parameter("horizon_radiance", "horizon_radiance")
                    self.__emit_parameter("zenith_radiance", "zenith_radiance")
                    self.__close_element('environment_edf')
                    
            elif scene.appleseed_sky.env_type == "latlong_map":
                if scene.appleseed_sky.env_tex != "":
                    self.__emit_texture(bpy.data.textures[scene.appleseed_sky.env_tex], False, scene)
                    self.__open_element('environment_edf name="{0}" model="latlong_map_environment_edf"'.format(env_edf_name))
                    self.__emit_parameter("radiance", scene.appleseed_sky.env_tex + "_inst")
                    self.__emit_parameter("radiance_multiplier", scene.appleseed_sky.env_tex_mult)
                    self.__close_element('environment_edf')
                else:
                    self.__warning("Latitude-Longitude environment texture is enabled, but no texture is assigned. Using gradient environment.")
                    self.__open_element('environment_edf name="{0}" model="gradient_environment_edf"'.format(env_edf_name))
                    self.__emit_parameter("horizon_radiance", "horizon_radiance")
                    self.__emit_parameter("zenith_radiance", "zenith_radiance")
                    self.__close_element('environment_edf')
                    
            elif scene.appleseed_sky.env_type == "sunsky":
                asr_sky = scene.appleseed_sky
                self.__open_element('environment_edf name="{0}" model="{1}"'.format(env_edf_name, asr_sky.sun_model))
                if asr_sky.sun_model == "hosek_environment_edf":
                    self.__emit_parameter("ground_albedo", asr_sky.ground_albedo)
                self.__emit_parameter("horizon_shift", asr_sky.horiz_shift)
                self.__emit_parameter("luminance_multiplier", asr_sky.luminance_multiplier)
                self.__emit_parameter("saturation_multiplier", asr_sky.saturation_multiplier)
                self.__emit_parameter("sun_phi", asr_sky.sun_phi)
                self.__emit_parameter("sun_theta", asr_sky.sun_theta)
                self.__emit_parameter("turbidity", asr_sky.turbidity)
                self.__emit_parameter("turbidity_max", asr_sky.turbidity_max)
                self.__emit_parameter("turbidity_min", asr_sky.turbidity_min)
                self.__close_element('environment_edf')

            # Write the environment shader.
            env_shader_name = "environment_shader"
            self.__open_element('environment_shader name="{0}" model="edf_environment_shader"'.format(env_shader_name))
            self.__emit_parameter("environment_edf", env_edf_name)
            self.__close_element('environment_shader')

        # Write the environment element.
        self.__open_element('environment name="environment" model="generic_environment"')
        if len(env_edf_name) > 0:
            self.__emit_parameter("environment_edf", env_edf_name)
        if len(env_shader_name) > 0:
            self.__emit_parameter("environment_shader", env_shader_name)
        self.__close_element('environment')
    
    #----------------------------------------------------------------------------------------------
    # Lights.
    #----------------------------------------------------------------------------------------------

    def __emit_light(self, scene, object):
        light_type = object.data.type
        
        if light_type == 'POINT':
            self.__emit_point_light(scene, object)
        elif light_type == 'SPOT':
            self.__emit_spot_light(scene, object)
        elif light_type == 'HEMI':
            self.__emit_directional_light( scene, object)
        elif light_type == 'SUN' and scene.appleseed_sky.env_type == "sunsky":
            self.__emit_sun_light(scene, object)
        elif light_type == 'SUN' and not scene.appleseed_sky.env_type == "sunsky":
            self.__warning("Sun lamp '{0}' exists in the scene, but sun/sky is not enabled".format(object.name))
            self.__emit_sun_light(scene, object)
        else:
            self.__warning("While exporting light '{0}': unsupported light type '{1}', skipping this light.".format(object.name, light_type))


    def __emit_sun_light(self, scene, lamp):
        lamp_data = lamp.data
        asr_light = lamp_data.appleseed
        sunsky = scene.appleseed_sky
        use_sunsky = sunsky.env_type == "sunsky"
        environment_edf = "environment_edf"
        
        self.__open_element('light name="{0}" model="sun_light"'.format(lamp.name))
        if bool(lamp.appleseed.render_layer):
            self._rules[ lamp.name] = lamp.appleseed.render_layer
        if use_sunsky:    
            self.__emit_parameter("environment_edf", environment_edf)
        self.__emit_parameter("radiance_multiplier", sunsky.radiance_multiplier if use_sunsky else asr_light.radiance_multiplier)
        self.__emit_parameter("turbidity", asr_light.turbidity)
        self.__emit_parameter("cast_indirect_light", str( asr_light.cast_indirect).lower())
        self.__emit_parameter("importance_multiplier", asr_light.importance_multiplier)
        self.__emit_transform_element(self._global_matrix * lamp.matrix_world, None)
        self.__close_element("light")

        
    def __emit_point_light(self, scene, lamp):
        lamp_data = lamp.data
        asr_light = lamp_data.appleseed
        radiance_name = "{0}_radiance".format(lamp.name)
        
        self.__emit_solid_linear_rgb_color_element(radiance_name, asr_light.radiance, 1)

        self.__open_element('light name="{0}" model="point_light"'.format(lamp.name))
        if bool( lamp.appleseed.render_layer):
            self._rules[ lamp.name] = lamp.appleseed.render_layer
        self.__emit_parameter("radiance", radiance_name)
        self.__emit_parameter("radiance_mutliplier", asr_light.radiance_multiplier)
        self.__emit_parameter("cast_indirect_light", str( asr_light.cast_indirect).lower())
        self.__emit_parameter("importance_multiplier", asr_light.importance_multiplier)
        self.__emit_transform_element(self._global_matrix * lamp.matrix_world, None)
        self.__close_element("light")


    def __emit_spot_light(self, scene, lamp):
        lamp_data = lamp.data
        asr_light = lamp_data.appleseed

        # Radiance.
        radiance_name = "{0}_radiance".format(lamp.name)
        if asr_light.radiance_use_tex and asr_light.radiance_tex != '':
            radiance_name = asr_light.radiance_tex + "_inst"
            if radiance_name not in self._textures_set:
                self.__emit_texture( bpy.data.textures[ asr_light.radiance_tex], False, scene)
                self._textures_set.add( radiance_name)
        else:
            self.__emit_solid_linear_rgb_color_element(radiance_name, asr_light.radiance, 1)

        # Radiance multiplier.
        radiance_multiplier = asr_light.radiance_multiplier
        if asr_light.radiance_multiplier_use_tex and asr_light.radiance_multiplier_tex != '':
            radiance_multiplier = asr_light.radiance_multiplier_tex + "_inst"
            if radiance_multiplier not in self._textures_set:
                self.__emit_texture( bpy.data.textures[ asr_light.radiance_multiplier_tex], False, scene)
                self._textures_set.add( radiance_multiplier)

        # Spot cone.
        outer_angle = math.degrees(lamp.data.spot_size)
        inner_angle = (1.0 - lamp.data.spot_blend) * outer_angle

        self.__open_element('light name="{0}" model="spot_light"'.format(lamp.name))
        if bool(lamp.appleseed.render_layer):
            self._rules[ lamp.name] = lamp.appleseed.render_layer
        self.__emit_parameter("radiance", radiance_name)
        self.__emit_parameter("radiance_multiplier", radiance_multiplier)
        self.__emit_parameter("inner_angle", inner_angle)
        self.__emit_parameter("outer_angle", outer_angle)
        self.__emit_parameter("cast_indirect_light", str( asr_light.cast_indirect).lower())
        self.__emit_parameter("importance_multiplier", asr_light.importance_multiplier)
        self.__emit_transform_element(self._global_matrix * lamp.matrix_world, None)
        self.__close_element("light")

    def __emit_directional_light(self, scene, lamp):
        lamp_data = lamp.data
        asr_light = lamp_data.appleseed
        radiance_name = "{0}_radiance".format(lamp.name)
        
        self.__emit_solid_linear_rgb_color_element(radiance_name, asr_light.radiance, 1)

        self.__open_element('light name="{0}" model="directional_light"'.format(lamp.name))
        if bool(lamp.appleseed.render_layer):
            self._rules[ lamp.name] = lamp.appleseed.render_layer
        self.__emit_parameter("radiance", radiance_name)
        self.__emit_parameter("radiance_multiplier", asr_light.radiance_multiplier)
        self.__emit_parameter("cast_indirect_light", str( asr_light.cast_indirect).lower())
        self.__emit_parameter("importance_multiplier", asr_light.importance_multiplier)
        self.__emit_transform_element(self._global_matrix * lamp.matrix_world, None)
        self.__close_element("light")
        
    #----------------------------------------------------------------------------------------------
    # Output.
    #----------------------------------------------------------------------------------------------

    def __emit_output(self, scene):
        self.__open_element("output")
        self.__emit_frame_element(scene)
        self.__close_element("output")

    def __emit_frame_element(self, scene):
        camera = scene.camera
        width, height = self.__get_frame_resolution(scene.render)
        self.__open_element("frame name=\"beauty\"")
        self.__emit_parameter("camera", "camera" if camera is None else camera.name)
        self.__emit_parameter("resolution", "{0} {1}".format(width, height))
        self.__emit_custom_prop(scene, "color_space", "srgb")
        if scene.render.use_border:
            X, Y, endX, endY = self.__get_border_limits(scene, width, height)
            self.__emit_parameter("crop_window", "{0} {1} {2} {3}".format(X, Y, endX, endY))
        self.__close_element("frame")

    def __get_frame_resolution(self, render):
        scale = render.resolution_percentage / 100.0
        width = int(render.resolution_x * scale)
        height = int(render.resolution_y * scale)
        return width, height

    def __get_frame_aspect_ratio(self, render):
        width, height = self.__get_frame_resolution(render)
        xratio = width * render.pixel_aspect_x
        yratio = height * render.pixel_aspect_y
        return xratio / yratio

    def __get_border_limits(self, scene, width, height):
        X = int(scene.render.border_min_x * width)
        Y = height - int(scene.render.border_max_y * height)
        endX = int(scene.render.border_max_x * width)    
        endY = height - int(scene.render.border_min_y * height)
        return X, Y, endX, endY

    #----------------------------------------------------------------------------------------------
    # Render layer assignments.
    #----------------------------------------------------------------------------------------------
    def __emit_rules( self, scene):
        if len( self._rules.keys()) > 0:
            self.__open_element( "rules")
            for ob_name in self._rules.keys():
                render_layer = self._rules[ ob_name]
                rule_name = "rule_%d" % self._rule_index
                self._emit_render_layer_assignment( rule_name, ob_name, render_layer)
                self._rule_index += 1
            self.__close_element( "rules")            
                        
    def _emit_render_layer_assignment( self, rule_name, ob_name, render_layer):
        # For now, all assignments are to "All" entity types
        self.__open_element( 'render_layer_assignment name="%s" model="regex"' % rule_name)
        self.__emit_parameter( "render_layer", render_layer)
        self.__emit_parameter( "order", 1)
        self.__emit_parameter( "pattern", ob_name)
        self.__close_element( "render_layer_assignment")
    #----------------------------------------------------------------------------------------------
    # Configurations.
    #----------------------------------------------------------------------------------------------

    def __emit_configurations(self, scene):
        self.__open_element("configurations")
        self.__emit_interactive_configuration_element(scene)
        self.__emit_final_configuration_element(scene)
        self.__close_element("configurations")

    def __emit_interactive_configuration_element(self, scene):
        self.__open_element('configuration name="interactive" base="base_interactive"')
        self.__emit_common_configuration_parameters(scene, "interactive")
        self.__close_element("configuration")

    def __emit_final_configuration_element(self, scene):
        self.__open_element('configuration name="final" base="base_final"')
        self.__emit_common_configuration_parameters(scene, "final")
        self.__open_element('parameters name="generic_tile_renderer"')
        self.__emit_parameter("min_samples", scene.appleseed.sampler_min_samples)
        self.__emit_parameter("max_samples", scene.appleseed.sampler_max_samples)
        self.__close_element("parameters")
        self.__close_element("configuration")

    def __emit_common_configuration_parameters(self, scene, type):
        # Interactive: always use drt
        lighting_engine = 'drt' if type == "interactive" else scene.appleseed.lighting_engine
        
        self.__emit_parameter("lighting_engine", lighting_engine)
        self.__emit_parameter("pixel_renderer", scene.appleseed.pixel_sampler)
        self.__emit_parameter("rendering_threads", scene.appleseed.threads)
        self.__open_element('parameters name="adaptive_pixel_renderer"')
        self.__emit_parameter("enable_diagnostics", scene.appleseed.enable_diagnostics)
        self.__emit_parameter("max_samples", scene.appleseed.sampler_max_samples)
        self.__emit_parameter("min_samples", scene.appleseed.sampler_min_samples)
        self.__emit_parameter("quality", scene.appleseed.quality)
        self.__close_element("parameters")

        self.__open_element('parameters name="uniform_pixel_renderer"')
        self.__emit_parameter("decorrelate_pixels", "true" if scene.appleseed.decorrelate_pixels else "false")
        self.__emit_parameter("force_antialiasing", "true" if scene.appleseed.force_aa else "false")
        self.__emit_parameter("samples", scene.appleseed.sampler_max_samples)
        self.__close_element("parameters")

        self.__open_element('parameters name="generic_frame_renderer"')
        self.__emit_parameter("passes", scene.appleseed.renderer_passes)
        self.__emit_parameter("tile_ordering", scene.appleseed.tile_ordering)
        self.__close_element("parameters")
        
        self.__open_element('parameters name="{0}"'.format(scene.appleseed.lighting_engine))
        # IBL can be enabled with all three engines.
        self.__emit_parameter("enable_ibl", "true" if scene.appleseed.ibl_enable else "false")
        
        if scene.appleseed.lighting_engine == 'pt':
            self.__emit_parameter("enable_dl", "true" if scene.appleseed.direct_lighting else "false")
            self.__emit_parameter("enable_caustics", "true" if scene.appleseed.caustics_enable else "false")
            self.__emit_parameter("next_event_estimation", "true" if scene.appleseed.next_event_est else "false")
            if scene.appleseed.max_ray_intensity > 0.0:
                self.__emit_parameter("max_ray_intensity", scene.appleseed.max_ray_intensity)

        if scene.appleseed.lighting_engine == 'pt' or scene.appleseed.lighting_engine == 'drt':
            self.__emit_parameter("dl_light_samples", scene.appleseed.dl_light_samples)
            self.__emit_parameter("ibl_env_samples", scene.appleseed.ibl_env_samples)
            self.__emit_parameter("max_path_length", scene.appleseed.max_bounces)
            self.__emit_parameter("rr_min_path_length", scene.appleseed.rr_start)

        else:
            self.__emit_parameter("alpha", scene.appleseed.sppm_alpha)
            self.__emit_parameter("dl_mode", scene.appleseed.sppm_dl_mode)
            self.__emit_parameter("enable_caustics", "true" if scene.appleseed.caustics_enable else "false")
            self.__emit_parameter("env_photons_per_pass", scene.appleseed.sppm_env_photons)
            self.__emit_parameter("initial_radius", scene.appleseed.sppm_initial_radius)
            self.__emit_parameter("light_photons_per_pass", scene.appleseed.sppm_light_photons)

            # Leave at 0 for now - not in appleseed.studio GUI
            self.__emit_parameter("max_path_length", 0)     
            self.__emit_parameter("max_photons_per_estimate", scene.appleseed.sppm_max_per_estimate)
            self.__emit_parameter("path_tracing_max_path_length", scene.appleseed.sppm_pt_max_length)
            self.__emit_parameter("path_tracing_rr_min_path_length", scene.appleseed.sppm_pt_rr_start)
            self.__emit_parameter("photon_tracing_max_path_length", scene.appleseed.sppm_photon_max_length)
            self.__emit_parameter("photon_tracing_rr_min_path_length", scene.appleseed.sppm_photon_rr_start)
            
            # Leave RR path length at 3 - also not in appleseed.studio GUI
            self.__emit_parameter("rr_min_path_length", 3)  
            
        self.__close_element('parameters')

    #----------------------------------------------------------------------------------------------
    # Common elements.
    #----------------------------------------------------------------------------------------------

    def __emit_color_element(self, name, color_space, values, alpha, multiplier):
        self.__open_element('color name="{0}"'.format(name))
        self.__emit_parameter("color_space", color_space)
        self.__emit_parameter("multiplier", multiplier)
        self.__emit_line("<values>{0}</values>".format(" ".join(map(str, values))))
        if alpha:
            self.__emit_line("<alpha>{0}</alpha>".format(" ".join(map(str, alpha))))
        self.__close_element("color")

    #
    # A note on color spaces:
    #
    # Internally, Blender stores colors as linear RGB values, and the numeric color values
    # we get from color pickers are linear RGB values, although the color swatches and color
    # pickers show gamma corrected colors. This explains why we pretty much exclusively use
    # __emit_solid_linear_rgb_color_element() instead of __emit_solid_srgb_color_element().
    #

    def __emit_solid_linear_rgb_color_element(self, name, values, multiplier):
        self.__emit_color_element(name, "linear_rgb", values, None, multiplier)

    def __emit_solid_srgb_color_element(self, name, values, multiplier):
        self.__emit_color_element(name, "srgb", values, None, multiplier)

    def __emit_transform_element(self, m, time):
        #
        # We have the following conventions:
        #
        #   Both Blender and appleseed use right-hand coordinate systems.
        #   Both Blender and appleseed use column-major matrices.
        #   Both Blender and appleseed use pre-multiplication.
        #   In Blender, given a matrix m, m[i][j] is the element at the i'th row, j'th column.
        #

        # The only difference between the coordinate systems of Blender and appleseed is the up vector:
        # in Blender, up is Z+; in appleseed, up is Y+. We can go from Blender's coordinate system to
        # appleseed's one by rotating by +90 degrees around the X axis. That means that Blender
        # objects must be rotated by -90 degrees around X before being exported to appleseed.
        #
        if time is not None:
            self.__open_element('transform time="%.2f"' % time)
        else: 
            self.__open_element("transform")
        self.__open_element("matrix")
        self.__emit_line("{0} {1} {2} {3}".format( m[0][0],  m[0][1],  m[0][2],  m[0][3]))
        self.__emit_line("{0} {1} {2} {3}".format( m[2][0],  m[2][1],  m[2][2],  m[2][3]))
        self.__emit_line("{0} {1} {2} {3}".format(-m[1][0], -m[1][1], -m[1][2], -m[1][3]))
        self.__emit_line("{0} {1} {2} {3}".format( m[3][0],  m[3][1],  m[3][2],  m[3][3]))
        self.__close_element("matrix")
        self.__close_element("transform")

    def __emit_custom_prop( self, object, prop_name, default_value):
        value = self.__get_custom_prop(object, prop_name, default_value)
        self.__emit_parameter(prop_name, value)

    def __get_custom_prop( self, object, prop_name, default_value):
        if prop_name in object:
            return object[prop_name]
        else:
            return default_value

    def __emit_parameter( self, name, value):
        self.__emit_line("<parameter name=\"" + name + "\" value=\"" + str(value) + "\" />")
    
    #----------------------------------------------------------------------------------------------
    # Utilities.
    #----------------------------------------------------------------------------------------------

    def __open_element( self, name):
        self.__emit_line("<" + name + ">")
        self.__indent()

    def __close_element( self, name):
        self.__unindent()
        self.__emit_line("</" + name + ">")

    def __emit_line( self, line):
        self.__emit_indent()
        self._output_file.write(line + "\n")

    def __indent( self):
        self._indent += 1

    def __unindent( self):
        assert self._indent > 0
        self._indent -= 1

    def __emit_indent( self):
        IndentSize = 4
        self._output_file.write(" " * self._indent * IndentSize)

    def __error( self, message):
        self.__print_message( "error", message)
        #self.report({ 'ERROR' }, message)

    def __warning( self, message):
        self.__print_message( "warning", message)
        #self.report({ 'WARNING' }, message)

    def __info( self, message):
        if len(message) > 0:
            self.__print_message( "info", message)
        else: print("")
        #self.report({ 'INFO' }, message)

    def __progress( self, message):
        self.__print_message( "progress", message)

    def __print_message( self, severity, message):
        max_length = 8  # length of the longest severity string
        padding_count = max_length - len(severity)
        padding = " " * padding_count
        print( "{0}{1} : {2}".format(severity, padding, message))

    #----------------------------------------------------------------------------------------------
    #   Preview render .appleseed file export
    #----------------------------------------------------------------------------------------------
    
    def export_preview(self, scene, file_path, addon_path, mat, mesh, width, height):
        '''Write the .appleseed project file for preview rendering'''
        
        self._textures_set = set()
        asr_mat = mat.appleseed
        sphere_a = True if mesh == 'sphere_a' else False
        mesh = 'sphere' if mesh in {'sphere', 'sphere_a'} else mesh
        
        try:
            with open(file_path, "w") as self._output_file:
                self._indent = 0
                self.__emit_file_header()
                aspect_ratio = self.__get_frame_aspect_ratio(scene.render)

                #Write the following generic scene file.
                self._output_file.write("""<project>
    <scene>
        <camera name="Camera" model="pinhole_camera">
            <parameter name="film_width" value="0.032" />
            <parameter name="aspect_ratio" value="{0}" />
            <parameter name="focal_length" value="0.035" />
            <transform>
                <look_at origin="0.0 0.04963580518960953 0.23966674506664276" target="0.0 0.04963589459657669 0.13966673612594604" up="0.0 0.10000001639127731 8.781765359344718e-08" />
            </transform>
        </camera>""".format(aspect_ratio))
                
                # Environment EDF.
                if not sphere_a:
                    self._output_file.write("""
        <color name="horizon_radiance">
            <parameter name="color_space" value="linear_rgb" />
            <parameter name="multiplier" value="1.0" />
            <values>0.4 0.4 0.4</values>
        </color>
        <color name="zenith_radiance">
            <parameter name="color_space" value="linear_rgb" />
            <parameter name="multiplier" value="1.0" />
            <values>0.0 0.0 0.0</values>
        </color>
        <environment_edf name="environment_edf" model="constant_environment_edf">
            <parameter name="radiance" value="horizon_radiance" />
        </environment_edf>
        <environment_shader name="environment_shader" model="edf_environment_shader">""")
                
                else:
                    self._output_file.write("""
        <color name="horizon_radiance">
            <parameter name="color_space" value="linear_rgb" />
            <parameter name="multiplier" value="1.0" />
            <values>0.8 0.77 0.7</values>
        </color>
        <color name="zenith_radiance">
            <parameter name="color_space" value="linear_rgb" />
            <parameter name="multiplier" value="1.0" />
            <values>0.5 0.5 0.9</values>
        </color>
        <environment_edf name="environment_edf" model="gradient_environment_edf">
            <parameter name="horizon_radiance" value="horizon_radiance" />
            <parameter name="zenith_radiance" value="zenith_radiance" />
        </environment_edf>
        <environment_shader name="environment_shader" model="edf_environment_shader">""")
                
                self._output_file.write("""
            <parameter name="environment_edf" value="environment_edf" />
        </environment_shader>
        <environment name="environment" model="generic_environment">
            <parameter name="environment_edf" value="environment_edf" />
            <parameter name="environment_shader" value="environment_shader" />
        </environment>""")
                
                # Preview lamp mesh.
                self._output_file.write("""
        <assembly name="mat_preview">
            <surface_shader name="physical_surface_shader" model="physical_surface_shader" />
            <color name="__default_material_albedo">
                <parameter name="color_space" value="linear_rgb" />

                <parameter name="multiplier" value="1.0" />
                <values>0.8 0.8 0.8</values>
            </color>
            <color name="__default_material_bsdf_reflectance">
                <parameter name="color_space" value="linear_rgb" />
                <parameter name="multiplier" value="1.0" />
                <values>0.8</values>

            </color>
            <bsdf name="__default_material_bsdf" model="lambertian_brdf">
                <parameter name="reflectance" value="__default_material_bsdf_reflectance" />
            </bsdf>
            <material name="__default_material" model="generic_material">
                <parameter name="bsdf" value="__default_material_bsdf" />

                <parameter name="surface_shader" value="physical_surface_shader" />
            </material>
            <object name="material_preview_lamp" model="mesh_object">
                <parameter name="filename" value="material_preview_lamp.obj" />
            </object>
            <color name="material_preview_lamp_material|BSDF Layer 1_lambertian_reflectance">

                <parameter name="color_space" value="linear_rgb" />
                <parameter name="multiplier" value="1.0" />
                <values>0.8 0.8 0.8</values>
            </color>
            <bsdf name="material_preview_lamp_material|BSDF Layer 1" model="lambertian_brdf">
                <parameter name="reflectance" value="material_preview_lamp_material|BSDF Layer 1_lambertian_reflectance" />
            </bsdf>

            <color name="material_preview_lamp_material_edf_radiance">
                <parameter name="color_space" value="linear_rgb" />
                <parameter name="multiplier" value="5.0" />
                <values>0.8 0.8 0.8</values>
            </color>
            <edf name="material_preview_lamp_material_edf" model="diffuse_edf">

                <parameter name="radiance" value="material_preview_lamp_material_edf_radiance" />
            </edf>

            <material name="material_preview_lamp_material" model="generic_material">
                <parameter name="bsdf" value="material_preview_lamp_material|BSDF Layer 1" />
                <parameter name="edf" value="material_preview_lamp_material_edf" />
                <parameter name="surface_shader" value="physical_surface_shader" />
            </material>
            <object_instance name="material_preview_lamp.part_0.instance_0" object="material_preview_lamp.part_0">
                <transform>
                    <matrix>
                        0.06069698929786682 0.07323580980300903 0.030860835686326027 0.0
                        0.0 -0.038832105696201324 0.0921524167060852 0.0
                        0.07947248220443726 -0.055933743715286255 -0.023569919168949127 -0.0
                        0.0 0.0 0.0 1.0
                    </matrix>
                </transform>
                <assign_material slot="0" side="front" material="material_preview_lamp_material" />
                <assign_material slot="0" side="back" material="__default_material" />
            </object_instance>
            <object name="material_preview_ground" model="mesh_object">
                <parameter name="filename" value="material_preview_ground.obj" />
            </object>""")

                # Preview ground plane.
                if not sphere_a:
                    self._output_file.write("""
            <texture name="material_preview_checker_texture" model="disk_texture_2d">
                <parameter name="color_space" value="srgb" />
                <parameter name="filename" value="checker_texture.png" />
            </texture>
            <texture_instance name="material_preview_checker_texture_inst" texture="material_preview_checker_texture">
                <parameter name="addressing_mode" value="wrap" />
                <parameter name="filtering_mode" value="bilinear" />
            </texture_instance>
            <bsdf name="material_preview_plane_material|BSDF Layer 1" model="lambertian_brdf">
                <parameter name="reflectance" value="material_preview_checker_texture_inst" />
            </bsdf>
            <material name="material_preview_plane_material" model="generic_material">
                <parameter name="bsdf" value="material_preview_plane_material|BSDF Layer 1" />
                <parameter name="surface_shader" value="physical_surface_shader" />
            </material>
            <object_instance name="material_preview_ground.part_0.instance_0" object="material_preview_ground.part_0">
                <transform>
                    <matrix>
                        0.10000000149011612 0.0 0.0 0.0
                        0.0 0.0 0.10000000149011612 0.0
                        -0.0 -0.10000000149011612 -0.0 -0.0
                        0.0 0.0 0.0 1.0
                    </matrix>
                </transform>
                <assign_material slot="0" side="front" material="material_preview_plane_material" />
                <assign_material slot="0" side="back" material="material_preview_plane_material" />
            </object_instance>""")

                # Preview mesh. 
                mat_front = mat.name
                mat_back = mat.name
                if self.__is_node_material( asr_mat):
                    material_node = bpy.data.node_groups[ asr_mat.node_tree].nodes[ asr_mat.node_output]
                    node_list = material_node.traverse_tree()
                    for node in node_list:
                        if node.node_type == 'specular_btdf':
                            mat_front = mat.name + "_front"
                            mat_back = mat.name + "_back"
                            break 
                else:
                    for layer in asr_mat.layers:
                        if layer.bsdf_type == 'specular_btdf':
                            mat_front = mat.name + "_front"
                            mat_back = mat.name + "_back"
                            break
                        
                self._output_file.write("""
            <object name="material_preview_{0}" model="mesh_object">
                <parameter name="filename" value="material_preview_{0}.obj" />
            </object>
            <object_instance name="material_preview_{0}.part_0.instance_0" object="material_preview_{0}.part_0">
                <transform>
                    <matrix>
                        0.10000000149011612 0.0 0.0 0.0
                        0.0 0.0 0.10000000149011612 0.0
                        -0.0 -0.10000000149011612 -0.0 -0.0
                        0.0 0.0 0.0 1.0
                    </matrix>
                </transform>
                <assign_material slot="0" side="front" material="{1}" />
                <assign_material slot="0" side="back" material="{2}" />
            </object_instance>""".format( mesh, mat_front, mat_back))

                # Write the material for the preview sphere
                self.__emit_material(mat, scene)

                self._output_file.write("""
        </assembly>
        <assembly_instance name="mat_preview_instance" assembly="mat_preview">
        </assembly_instance>
    </scene>
    <output>
        <frame name="beauty">
            <parameter name="camera" value="Camera" />
            <parameter name="resolution" value="{0} {1}" />
            <parameter name="color_space" value="srgb" />
        </frame>
    </output>
    <configurations>
        <configuration name="interactive" base="base_interactive">
            <parameter name="lighting_engine" value="drt" />
            <parameter name="pixel_renderer" value="uniform" />
            <parameters name="adaptive_pixel_renderer">
                <parameter name="enable_diagnostics" value="False" />
                <parameter name="max_samples" value="8" />
                <parameter name="min_samples" value="2" />
                <parameter name="quality" value="3.0" />
            </parameters>
            <parameters name="uniform_pixel_renderer">
                <parameter name="decorrelate_pixels" value="False" />
                <parameter name="samples" value="4" />
            </parameters>
            <parameters name="drt">
                <parameter name="dl_light_samples" value="1" />
                <parameter name="enable_ibl" value="true" />
                <parameter name="ibl_env_samples" value="1" />

                <parameter name="rr_min_path_length" value="3" />
            </parameters>
        </configuration>
        <configuration name="final" base="base_final">
            <parameter name="lighting_engine" value="drt" />
            <parameter name="pixel_renderer" value="uniform" />
            <parameters name="adaptive_pixel_renderer">
                <parameter name="enable_diagnostics" value="False" />
                <parameter name="max_samples" value="8" />
                <parameter name="min_samples" value="2" />
                <parameter name="quality" value="3.0" />
            </parameters>
            <parameters name="uniform_pixel_renderer">
                <parameter name="decorrelate_pixels" value="False" />
                <parameter name="samples" value="{2}" />
            </parameters>
            <parameters name="drt">
                <parameter name="dl_light_samples" value="1" />
                <parameter name="enable_ibl" value="true" />
                <parameter name="ibl_env_samples" value="1" />
                <parameter name="rr_min_path_length" value="3" />
            </parameters>
            <parameters name="generic_tile_renderer">
                <parameter name="min_samples" value="{2}" />
                <parameter name="max_samples" value="{2}" />
            </parameters>
        </configuration>
    </configurations>
</project>""".format(int(width), int(height), asr_mat.preview_quality))
            return True
        except:
            self.__error( "Could not open %s for writing" % file_path) 
            return False
